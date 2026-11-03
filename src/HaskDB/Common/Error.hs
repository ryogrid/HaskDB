-- | 'SqlError' exceptions and SQLSTATE constructors.
--   Refines internal-design/00 §0.4 and design/09 §9.6.
--   Library code throws these for every user-visible failure; only
--   'Server.Session' catches them (internal/00 global rule 4).
module HaskDB.Common.Error where

import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)

data SqlError = SqlError { seState :: !Text, seMessage :: !Text }
  deriving (Show)
instance Exception SqlError

-- | Throw a SQLSTATE + message (internal/00 §0.4).
throwSql :: (MonadIO m) => Text -> Text -> m a
throwSql state msg = liftIO (throwIO (SqlError state msg))

-- Frequently used constructors (design/09 §9.6 error mapping table).
errSyntax :: Text -> SqlError
errSyntax msg = SqlError "42601" msg

errFeatureNotSupported :: Text -> SqlError
errFeatureNotSupported msg = SqlError "0A000" msg

errUndefinedTable :: Text -> SqlError
errUndefinedTable name = SqlError "42P01" ("table not found: " <> name)

errUndefinedColumn :: Text -> SqlError
errUndefinedColumn name = SqlError "42703" ("column not found: " <> name)

-- 42702 follows PostgreSQL (design/09 §9.6 is silent; recorded deviation).
errAmbiguous :: Text -> SqlError
errAmbiguous name = SqlError "42702" ("ambiguous column name: " <> name)

errDupName :: Text -> SqlError
errDupName name = SqlError "42P07" ("duplicate relation name: " <> name)

errDupColumn :: Text -> SqlError
errDupColumn name = SqlError "42701" ("duplicate column name: " <> name)

errGrouping :: SqlError
errGrouping = SqlError "42803" "grouping violation"

errTypeMismatch :: SqlError
errTypeMismatch = SqlError "42804" "type mismatch"

errInvalidLiteral :: Text -> SqlError
errInvalidLiteral msg = SqlError "22P02" msg

errStringTooLong :: SqlError
errStringTooLong = SqlError "22001" "value exceeds VARCHAR length limit (1024 bytes)"

errScalarSubqRows :: Text -> SqlError
errScalarSubqRows msg = SqlError "21000" msg

-- D-09 provisional: empty-input error reuses 21000 (internal/09 §9.3).
errAggEmptyInput :: SqlError
errAggEmptyInput = SqlError "21000" "aggregate over empty input"

errIntOverflow :: SqlError
errIntOverflow = SqlError "22003" "integer arithmetic overflow"

errTupleTooLarge :: SqlError
errTupleTooLarge = SqlError "54000" "tuple too large for page"

errMemoryLimit :: SqlError
errMemoryLimit = SqlError "54000" "sort/materialisation memory limit exceeded"

errDeadlock :: SqlError
errDeadlock = SqlError "40P01" "deadlock detected"

errLockTimeout :: SqlError
errLockTimeout = SqlError "55P03" "lock wait timeout"

errFailedBlock :: SqlError
errFailedBlock = SqlError "25P02" "statement executed in a failed transaction block"

-- design/09 §9.6 is silent; 42703 follows internal/07 note (use 42703).
errOrderBy :: SqlError
errOrderBy = SqlError "42703" "ORDER BY term does not match an output column"

errInternal :: Text -> SqlError
errInternal msg = SqlError "XX000" msg

-- Helper for sites that have an errInternal-style message to throw.
throwInternal :: (MonadIO m) => Text -> m a
throwInternal = throwSql "XX000"
