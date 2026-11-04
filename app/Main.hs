-- | haskdb-server (internal-design/11 §11.1): hand-rolled argument parsing,
--   open/create the database (§11.2), signal handlers (§11.5), then the
--   listener blocks forever.  Unknown flags and a missing dataDir print
--   usage to stderr and exit 1.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure, ExitCode(ExitFailure))
import System.IO (hPutStrLn, stderr)
import Control.Exception (catch, SomeException, fromException, throwIO)
import Data.Text (unpack)
import HaskDB.Common.Config (defaultConfig, cfgPort)
import HaskDB.Common.Error (SqlError(seMessage))
import HaskDB.Server.Listener (startDatabase, runListener, Database)

main :: IO ()
main = do
  argv <- getArgs
  case parseArgs argv of
    Nothing -> do
      hPutStrLn stderr (usage (progName argv))
      exitFailure
    Just (dir, mport) -> do
      let cfg0 = defaultConfig dir
          cfg = case mport of
                  Just p  -> cfg0 { cfgPort = p }
                  Nothing -> cfg0
      db <- startDatabase cfg `catch` startupDie
      runListener db

-- | §11.2's "die <message>": an open/create failure (a corrupt control file, a
--   pageSize disagreement, a replay error, a lost flock) prints the cause on
--   stderr and exits 1.  Without this handler GHC's default top-level handler
--   would print SqlError's Show, backtrace included.
startupDie :: SomeException -> IO Database
startupDie ex = case fromException ex of
  Just (ExitFailure _) -> throwIO ex        -- our own die: exit quietly
  _ -> do
    hPutStrLn stderr ("haskdb-server: " ++ reason ex)
    exitFailure
  where
    reason e = case fromException e of
                 Just se -> unpack (seMessage se)
                 Nothing  -> show e

-- | @haskdb-server <dataDir> [--port N] [--create]@.  '--create' is accepted
--   and ignored: §11.2 makes the absence of the control file the create
--   signal (guarded by the empty-directory check), so the flag cannot mean
--   anything else.
parseArgs :: [String] -> Maybe (FilePath, Maybe Int)
parseArgs args = walk args Nothing Nothing
  where
    walk rest accDir accPort = case rest of
      [] -> case accDir of
              Just d  -> Just (d, accPort)
              Nothing -> Nothing
      (a : as)
        | a == "--port" -> case as of
            (v : vs) -> case reads v of
                          [(p, "")] | p > (0 :: Int), p <= (65535 :: Int)
                            -> walk vs accDir (Just p)
                          _ -> Nothing
            [] -> Nothing
        | a == "--create" -> walk as accDir accPort
        | take 2 a == "--" -> Nothing                 -- unknown flag
        | otherwise -> case accDir of
            Nothing -> walk as (Just a) accPort
            Just _  -> Nothing                        -- stray positional

-- | The invoked program name, for the usage line (§11.1 prints usage).
progName :: [String] -> String
progName argv = case argv of
  (p : _) -> p
  []      -> "haskdb-server"

usage :: String -> String
usage prog =
  "usage: " ++ prog ++ " <dataDir> [--port N] [--create]\n"
  ++ "  starts the HaskDB server for the database in <dataDir>;\n"
  ++ "  --port overrides the configured port (default 54329);\n"
  ++ "  --create is accepted and ignored (a missing control file in an\n"
  ++ "  otherwise empty directory creates the database; stray files refuse)"
