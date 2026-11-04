-- | HaskDB.Server.Socket (internal-design/11 §11.3; design/09 §9.7): the
--   concrete socket behind 'Connection'.
--
--   Deviation (D-24, amends D-06): D-06 chose the @network@ package, but it
--   is not a GHC boot library and cannot be built with this toolchain — its
--   Setup script needs a statically linked @hsc2hs@, and this box has no
--   static gmp ('/usr/bin/ld: cannot find -lgmp').  The socket layer is
--   therefore a thin libc shim ("c/hs-socket.c") reached through GHC's FFI,
--   which keeps design/00 §0.1's "in principle boot libraries only" rule
--   intact.  Internal/11 §11.3 only demands that the socket implementation
--   lives below the 'Connection' abstraction, which is what this module does.
--
--   FFI notes (learned on this toolchain, logged in TODO.md): 'ByteString'
--   cannot be marshalled in a foreign call at all ('Unacceptable argument
--   type'), so bytes cross as 'Ptr CChar'; and the buffer must be copied
--   byte for byte ('peekArray') rather than through 'peekCAStringLen',
--   which would stop at the first NUL — every wire frame starts with NULs.
{-# LANGUAGE ForeignFunctionInterface, OverloadedStrings, ScopedTypeVariables,
             LambdaCase, BlockArguments, TupleSections #-}

module HaskDB.Server.Socket (Socket, listenOnPort, acceptPeer, closeSocket,
                             recvBytes, sendBytes, connPending, newConnection) where

import Foreign.C.Types (CChar(..), CInt(..), CLong(..))
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Marshal.Alloc (mallocBytes, free)
import Foreign.C.String (peekCAString)
import Foreign.Marshal.Array (peekArray, pokeArray)
import Data.Word (Word8)
import Data.Int (Int8)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Control.Exception (throwIO, ErrorCall(..))
import Data.IORef (IORef, newIORef, atomicModifyIORef')

import HaskDB.Server.Session (Connection(..))

-- ---------------------------------------------------------------------------
-- The libc shim (c/hs-socket.c).  Failing calls return -errno.
-- ---------------------------------------------------------------------------
foreign import ccall unsafe "hs_listen" cListen :: CInt -> IO CInt
-- accept/read/write can block for as long as the peer is quiet.  A *blocking*
-- FFI call issued by a lightweight thread freezes its whole capability, which
-- would stall every other session (and the listener's own next accept): with
-- 'safe' imports GHC releases the capability while the call is in flight,
-- which is what makes concurrent sessions work.  ('safe' also blocks SIGINT/
-- SIGTERM for the call's extent, which is why 'hs_accept' is reached only
-- after 'hs_conn_pending' says a peer is ready — see 'Listener.acceptLoop'.)
foreign import ccall safe "hs_accept" cAccept :: CInt -> IO CInt
foreign import ccall safe "hs_read_some"
  cReadSome :: CInt -> Ptr CChar -> CLong -> IO CLong
foreign import ccall safe "hs_write_some"
  cWriteSome :: CInt -> Ptr CChar -> CLong -> IO CLong
foreign import ccall unsafe "hs_conn_pending" cConnPending :: CInt -> IO CInt
foreign import ccall unsafe "hs_close_fd" cCloseFd :: CInt -> IO ()
foreign import ccall unsafe "hs_strerror_into"
  cStrerrorInto :: CInt -> Ptr CChar -> CInt -> IO ()

-- | True when a connection is queued on the listening socket, 'False' when
--   none is ready yet, and an error when the socket itself has gone bad.
connPending :: Socket -> IO Bool
connPending s = do
  r <- cConnPending (shFd s)
  if r > 0 then pure True
    else if r == 0 then pure False
      else dieWith (fromIntegral r) "listening socket is not polling"

-- | A socket is a descriptor plus a closed-flag: §11.5 closes every tracked
--   connection, and the session's own cleanup closes it too, so the close
--   must be guarded — a descriptor freed by the first close could otherwise
--   be reused by an unrelated fd and closed twice by accident.
data Socket = Socket { shFd :: CInt, shOpen :: IORef Bool }

-- ---------------------------------------------------------------------------
-- §11.3 step 1-2: bind (cfgPort, all interfaces), listen / accept
-- ---------------------------------------------------------------------------
listenOnPort :: Int -> IO Socket
listenOnPort port = do
  fd <- cListen (fromIntegral port)
  if fd < 0
    then dieWith (fromIntegral fd) "listen/bind failed"
    else Socket fd <$> newIORef True

acceptPeer :: Socket -> IO Socket
acceptPeer s = do
  fd <- cAccept (shFd s)
  if fd < 0
    then dieWith (fromIntegral fd) "accept failed"
    else Socket fd <$> newIORef True

-- | Closing is idempotent (see the flag above).
closeSocket :: Socket -> IO ()
closeSocket s = do
  wasOpen <- atomicModifyIORef' (shOpen s) (\c -> (True, c))
  if wasOpen then cCloseFd (shFd s) else pure ()

-- ---------------------------------------------------------------------------
-- 'Connection' (internal/11 §11.3): up to N bytes per recv, empty = EOF
-- ---------------------------------------------------------------------------
recvBytes :: Socket -> Int -> IO ByteString
recvBytes s cap
  | cap <= 0 = pure BS.empty
  | otherwise = do
      buf <- mallocBytes cap
      r <- cReadSome (shFd s) buf (fromIntegral cap)
      if r < 0
        then free buf >> dieWith (fromIntegral r) "read failed"
        else if r == 0
          then free buf >> pure BS.empty            -- clean EOF
          else do
            -- wire frames are full of NUL bytes, so the buffer is copied
            -- byte for byte: a CAString round trip would cut at the first
            -- NUL (and ByteString cannot be marshalled in a foreign call)
            bytes <- peekArray (fromIntegral r :: Int) buf
            free buf
            pure (BS.pack (map byteOf bytes))

-- | 'CChar' wraps a signed 8-bit value; widen modulo 2^8 for 'BS.pack'.
byteOf :: CChar -> Word8
byteOf (CChar w) = fromIntegral w

-- | Writing loops until every byte is accepted (a blocking socket, so a short
--   write means the kernel accepted part of the buffer).  Bytes are marshalled
--   one CChar at a time: the wire stream is full of NULs, so a CAString round
--   trip (which also re-encodes Chars) is not usable here.  A zero-length
--   progress step would spin forever, so it is an error.
sendBytes :: Socket -> ByteString -> IO ()
sendBytes s bs = do
  let total = BS.length bs
  buf <- mallocBytes (total + 1)
  pokeArray buf (map ccharOf (BS.unpack bs))
  let go off | off >= total = free buf
             | otherwise = do
                 w <- cWriteSome (shFd s) (plusPtr buf off) (fromIntegral (total - off))
                 if w < 0
                   then free buf >> dieWith (fromIntegral w) "write failed"
                   else if w == 0
                     then free buf >> dieWith (-1) "write made no progress"
                     else go (off + fromIntegral w)
  go 0

-- | 'CChar' wraps a signed 8-bit value; widen modulo 2^8.
ccharOf :: Word8 -> CChar
-- 'CChar' wraps a SIGNED 8-bit value, so 'toEnum' refuses 128..255 outright
--   ("tag (220) is outside of bounds"); a wire byte is wrapped modulo 2^8 and
--   read back the same way by 'byteOf'.
ccharOf w = CChar (fromIntegral w :: Int8)

newConnection :: Socket -> Connection
newConnection s = Connection { connRecv = recvBytes s, connSend = sendBytes s
                             , connClose = closeSocket s }

-- ---------------------------------------------------------------------------
-- Reporting a shim failure (§11.2/§11.5's "die with the real cause")
-- ---------------------------------------------------------------------------
dieWith :: Int -> String -> IO a
dieWith code what = do
  buf <- mallocBytes 256
  cStrerrorInto (fromIntegral code) buf 256
  msg <- peekCAString buf
  free buf
  throwIO (ErrorCall ("socket " ++ what ++ " (errno " ++ show code
                      ++ "): " ++ msg))
