-- * -*- eval: (orgstruct-mode 1); orgstruct-heading-prefix-regexp:"-- "; -*-
-- ** doc
-- In Emacs, use TAB on lines beginning with "-- *" to collapse/expand sections.
{-|

A reader for the "timedot" file format.
Example:

@
#DATE
#ACCT  DOTS  # Each dot represents 15m, spaces are ignored
#ACCT  8    # numbers with or without a following h represent hours
#ACCT  5m   # numbers followed by m represent minutes

# on 2/1, 1h was spent on FOSS haskell work, 0.25h on research, etc.
2/1
fos.haskell   .... ..
biz.research  .
inc.client1   .... .... .... .... .... ....

2/2
biz.research  .
inc.client1   .... .... ..

@

-}

-- ** language
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- ** doctest setup
-- $setup
-- >>> :set -XOverloadedStrings

-- ** exports
module Hledger.Read.TimedotReader (
  -- * Reader
  reader,
  -- * Misc other exports
  timedotfilep,
)
where

-- ** imports
import Prelude ()
import "base-compat-batteries" Prelude.Compat
import Control.Monad
import Control.Monad.Except (ExceptT)
import Control.Monad.State.Strict
import Data.Char (isSpace)
import Data.List (foldl')
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Text.Megaparsec hiding (parse)
import Text.Megaparsec.Char

import Hledger.Data
import Hledger.Read.Common
import Hledger.Utils

-- ** reader

reader :: Reader
reader = Reader
  {rFormat     = "timedot"
  ,rExtensions = ["timedot"]
  ,rParser     = parse
  ,rExperimental = False
  }

-- | Parse and post-process a "Journal" from the timedot format, or give an error.
parse :: InputOpts -> FilePath -> Text -> ExceptT String IO Journal
parse = parseAndFinaliseJournal' timedotfilep

-- ** utilities

traceparse :: Monad m => a -> m a
traceparse = return
-- traceparse :: String -> JournalParser m ()
-- traceparse = lift.traceParse

-- ** parsers

timedotfilep :: JournalParser m ParsedJournal
timedotfilep = do many timedotfileitemp
                  eof
                  get

timedotfileitemp :: JournalParser m ()
timedotfileitemp = do
  traceparse "timedotfileitemp"
  choice [
    try $ void $ lift emptyorcommentlinep'
   ,try timedotdayp >>= \ts -> modify' (addTransactions ts)
   ,lift $ skipSome anySingle >> eolof  -- an initial line not beginning with a date, ignore
   ] <?> "timedot day entry, or default year or comment line or blank line"

addTransactions :: [Transaction] -> Journal -> Journal
addTransactions ts j = foldl' (flip ($)) j (map addTransaction ts)

emptyorcommentlinep' = optional orgheadingprefixp >> emptyorcommentlinep

orgheadingprefixp = skipSome (char '*') >> skipSome spacenonewline

-- | Parse timedot day entries to zero or more time transactions for that day.
-- @
-- 2020/2/1 optional day description
-- fos.haskell  .... ..
-- biz.research .
-- inc.client1  .... .... .... .... .... ....
-- @
timedotdayp :: JournalParser m [Transaction]
timedotdayp = do
  traceparse " timedotdayp"
  lift $ optional orgheadingprefixp
  d <- datep
  daydesc <- strip <$> lift restofline
  es <- catMaybes <$> many (const Nothing <$> try (lift emptyorcommentlinep') <|>
                            Just <$> (notFollowedBy datep >> timedotentryp))
  return $ map (\t -> t{tdate=d, tdescription=T.pack daydesc}) es -- <$> many timedotentryp

-- | Parse a single timedot entry to one (dateless) transaction.
-- @
-- fos.haskell  .... ..
-- @
timedotentryp :: JournalParser m Transaction
timedotentryp = do
  traceparse "  timedotentryp"
  pos <- genericSourcePos <$> getSourcePos
  lift $ optional $ choice [orgheadingprefixp, skipSome spacenonewline]
  a <- modifiedaccountnamep
  lift (skipMany spacenonewline)
  hours <-
    try (lift followingcommentp >> return 0)
    <|> (timedotdurationp <*
         (try (lift followingcommentp) <|> (newline >> return "")))
  let t = nulltransaction{
        tsourcepos = pos,
        tstatus    = Cleared,
        tpostings  = [
          nullposting{paccount=a
                     ,pamount=Mixed [setAmountPrecision 2 $ num hours]  -- don't assume hours; do set precision to 2
                     ,ptype=VirtualPosting
                     ,ptransaction=Just t
                     }
          ]
        }
  return t

timedotdurationp :: JournalParser m Quantity
timedotdurationp = try timedotnumericp <|> timedotdotsp

-- | Parse a duration of seconds, minutes, hours, days, weeks, months or years,
-- written as a decimal number followed by s, m, h, d, w, mo or y, assuming h
-- if there is no unit. Returns the duration as hours, assuming
-- 1m = 60s, 1h = 60m, 1d = 24h, 1w = 7d, 1mo = 30d, 1y=365d.
-- @
-- 1.5
-- 1.5h
-- 90m
-- @
timedotnumericp :: JournalParser m Quantity
timedotnumericp = do
  (q, _, _, _) <- lift $ numberp Nothing
  msymbol <- optional $ choice $ map (string . fst) timeUnits
  lift (skipMany spacenonewline)
  let q' =
        case msymbol of
          Nothing  -> q
          Just sym ->
            case lookup sym timeUnits of
              Just mult -> q * mult
              Nothing   -> q  -- shouldn't happen.. ignore
  return q'

-- (symbol, equivalent in hours).
timeUnits =
  [("s",2.777777777777778e-4)
  ,("mo",5040) -- before "m"
  ,("m",1.6666666666666666e-2)
  ,("h",1)
  ,("d",24)
  ,("w",168)
  ,("y",61320)
  ]

-- | Parse a quantity written as a line of dots, each representing 0.25.
-- @
-- .... ..
-- @
timedotdotsp :: JournalParser m Quantity
timedotdotsp = do
  dots <- filter (not.isSpace) <$> many (oneOf (". " :: [Char]))
  return $ (/4) $ fromIntegral $ length dots
