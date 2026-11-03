-- | SQL lexer (internal-design/07 §7.1; design/05 §5.1).  Byte-oriented:
--   input validated as UTF-8 up-front (22P02), identifiers/keywords ASCII
--   lower-cased, `--` comments stripped here, INT64-overflow integer
--   literals -> 22003 AT LEX TIME, keywords NOT reserved (parser
--   compares TIdent text).  Deviation recorded in TODO.md: UTF-8
--   validation via Data.Text.Encoding.decodeUtf8' of the whole input
--   instead of a hand-rolled DFA; tokPos counts BYTES.
module HaskDB.Sql.Lexer where

import qualified Data.ByteString as BS
import Data.Text (Text, pack, unpack, singleton)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Int (Int64)
import Data.Char (chr)
import Text.Read (readMaybe)
import HaskDB.Common.Error (SqlError(..), errSyntax)

data Token
  = TIdent  !Text
  | TInt    !Int64
  | TFloat  !Double
  | TString !BS.ByteString
  | TSymbol !Char
  | TNe | TLe | TGe
  | TEOF
  deriving (Eq, Show)

data Tok = Tok { tokPos :: !Int, tokVal :: Token }  -- byte offset in input
  deriving (Eq, Show)

-- | Whole-input UTF-8 validation (§7.1 rule 1).
validateUtf8 :: BS.ByteString -> Either SqlError ()
validateUtf8 bs =
  case TE.decodeUtf8' bs of
    Left _  -> Left (SqlError "22P02" "invalid UTF-8 in SQL input")
    Right _ -> Right ()

-- | Lex the entire statement string; TEOF always terminates.
lexSql :: BS.ByteString -> Either SqlError [Tok]
lexSql input = do
  validateUtf8 input
  go 0 input []
  where
    go pos bs acc =
      let (pos1, bs1) = skipTrivia pos bs
      in if BS.null bs1
           then Right (reverse (Tok pos1 TEOF : acc))
           else case scanTok pos1 bs1 of
                  Left e -> Left e
                  Right (t, pos2, bs2) -> go pos2 bs2 (Tok pos1 t : acc)

-- | Whitespace and `--` comments, repeatedly.
skipTrivia :: Int -> BS.ByteString -> (Int, BS.ByteString)
skipTrivia pos bs0
  | not (BS.null bs0)
  , BS.head bs0 == 0x20 || BS.head bs0 == 0x09
  || BS.head bs0 == 0x0D || BS.head bs0 == 0x0A
  = let n = BS.length (BS.takeWhile isSpace8 bs0)
    in skipTrivia (pos + n) (BS.drop n bs0)
  | otherwise = case commentAhead bs0 of
      Just (n, rest) -> skipTrivia (pos + n) rest
      Nothing        -> (pos, bs0)
  where
    isSpace8 c = c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A
    commentAhead bs
      | BS.length bs >= 2
      , BS.index bs 0 == 0x2D
      , BS.index bs 1 == 0x2D
      = let body = BS.drop 2 bs
            t = BS.length (BS.takeWhile (/= 0x0A) body)
        in Just (2 + t, BS.drop t body)
      | otherwise = Nothing

-- | One token at the head of `bs` (non-empty, not trivia).
scanTok :: Int -> BS.ByteString -> Either SqlError (Token, Int, BS.ByteString)
scanTok p bs = case BS.index bs 0 of
  0x28 -> right (TSymbol '(') 1
  0x29 -> right (TSymbol ')') 1
  0x2C -> right (TSymbol ',') 1
  0x3B -> right (TSymbol ';') 1
  0x2A -> right (TSymbol '*') 1
  0x2E -> right (TSymbol '.') 1   -- qualified names (ColRef in §7.2 needs it)
  0x3D -> right (TSymbol '=') 1
  0x3C -> if BS.length bs >= 2 && BS.index bs 1 == 0x3E
            then right TNe 2
            else if BS.length bs >= 2 && BS.index bs 1 == 0x3D
              then right TLe 2
              else right (TSymbol '<') 1
  0x3E -> if BS.length bs >= 2 && BS.index bs 1 == 0x3D
            then right TGe 2
            else right (TSymbol '>') 1
  0x27 -> lexStr p bs
  c | isDigit c -> lexNum p bs
  c | c == 0x2D
    , BS.length bs >= 2
    , isDigit (BS.index bs 1) -> lexNum p bs
  c | isAlpha8 c || c == 0x5F -> lexIdent p bs
  c -> Left (errSyntax ("unexpected character: " <> singleton (chr (fromIntegral c))))
  where
    right t k = Right (t, p + k, BS.drop k bs)
    isAlpha8 c = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    isDigit c = c >= 0x30 && c <= 0x39

-- | Numeric literal: digits [. digits] [eE [+-] digits], optional leading
--   '-'.  Int when no fraction/exponent; INT64 overflow -> 22003 AT LEX
--   TIME (§7.1).  A float whose text denotes a NON-FINITE value (1e400)
--   is rejected (22P02), enforcing design/05 §5.4's "Infinity literals
--   are likewise rejected" rule.  A '.' with no digit after it is NOT a
--   number: it lexes as the TSymbol '.', used only by qualified names.
lexNum :: Int -> BS.ByteString -> Either SqlError (Token, Int, BS.ByteString)
lexNum p bs =
  let neg = BS.index bs 0 == 0x2D
      body = if neg then BS.drop 1 bs else bs
      intPart = BS.takeWhile isDigit8 body
      afterInt = BS.drop (BS.length intPart) body
      frac
        | BS.length afterInt >= 2
        , BS.head afterInt == 0x2E
        , isDigit8 (BS.index afterInt 1)
        = BS.singleton 0x2E <> BS.takeWhile isDigit8 (BS.drop 1 afterInt)
        | otherwise = BS.empty
      afterFrac = BS.drop (BS.length frac) afterInt
      expPart = case takeExp afterFrac of
                  Just e  -> e
                  Nothing -> BS.empty
      numText = intPart <> frac <> expPart
      consumed = BS.length numText + (if neg then 1 else 0)
      str = (if neg then "-" else "") ++ unpack (decodeAscii numText)
      isFloatText = '.' `elem` str || 'e' `elem` str || 'E' `elem` str
  in if BS.null numText
     then Left (errSyntax "invalid numeric literal")
     else if isFloatText
       then case readMaybe str :: Maybe Double of
              Just d | not (isNaN d) && not (isInfinite d)
                     -> Right (TFloat d, p + consumed, BS.drop consumed bs)
                     | otherwise
                     -> Left (SqlError "22P02"
                         ("float literal is not finite: " <> pack str))
              Nothing -> Left (SqlError "22P02" ("bad float literal: " <> pack str))
       else case readMaybe str :: Maybe Integer of
              Just i | i >= toInteger (minBound :: Int64)
                     && i <= toInteger (maxBound :: Int64)
                     -> Right (TInt (fromInteger i), p + consumed, BS.drop consumed bs)
                     | otherwise -> Left (SqlError "22003"
                            ("integer literal overflows INT64: " <> pack str))
              Nothing -> Left (SqlError "22P02" ("bad integer literal: " <> pack str))
  where
    decodeAscii b = pack (map (chr . fromIntegral) (BS.unpack b))
    isDigit8 c = c >= 0x30 && c <= 0x39
    takeExp a
      | not (BS.null a), BS.head a == 0x65 || BS.head a == 0x45 =
          let b = BS.drop 1 a
              sgn = if not (BS.null b)
                       && (BS.head b == 0x2B || BS.head b == 0x2D)
                      then BS.take 1 b else BS.empty
              ds = BS.takeWhile isDigit8 (BS.drop (BS.length sgn) b)
          in if BS.null ds then Nothing else Just (BS.take 1 a <> sgn <> ds)
      | otherwise = Nothing

-- | String literal: single quotes, doubled quote escapes; content bytes
--   must be valid UTF-8 (already checked for the whole input).
lexStr :: Int -> BS.ByteString -> Either SqlError (Token, Int, BS.ByteString)
lexStr p bs = walk 1 BS.empty (BS.drop 1 bs)
  where
    walk off acc rest
      | BS.null rest = Left (errSyntax "unterminated string literal")
      | BS.head rest == quote =
          if BS.length rest >= 2 && BS.index rest 1 == quote
            then walk (off + 2) (acc <> BS.singleton quote) (BS.drop 2 rest)
            else Right (TString acc, p + off + 1, BS.drop (off + 1) bs)
      | otherwise = let n = BS.length (BS.takeWhile (/= quote) rest)
                    in walk (off + n) (acc <> BS.take n rest) (BS.drop n rest)
    quote = 0x27

-- | Identifier/keyword text, ASCII letters/digits/underscore, lower-cased
--   (§5.1: identifiers stored lower-cased; keyword detection in parser).
lexIdent :: Int -> BS.ByteString -> Either SqlError (Token, Int, BS.ByteString)
lexIdent p bs =
  let n = BS.length (BS.takeWhile identChar bs)
      t = T.toLower (pack (map (chr . fromIntegral) (BS.unpack (BS.take n bs))))
  in if n == 0
       then Left (errSyntax "invalid identifier start")
       else Right (TIdent t, p + n, BS.drop n bs)
  where
    identChar c = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
               || (c >= 0x30 && c <= 0x39) || c == 0x5F













