{-|
A history-aware add command to help with data entry.
|-}

{-# OPTIONS_GHC -fno-warn-missing-signatures -fno-warn-unused-do-bind #-}
{-# LANGUAGE ScopedTypeVariables, DeriveDataTypeable, RecordWildCards, TypeOperators, FlexibleContexts #-}

module Hledger.Cli.Add
where

import Control.Exception as E
import Control.Monad
import Control.Monad.Trans (liftIO)
import Data.Char (toUpper, toLower)
import Data.List
import Data.Maybe
import Data.Time.Calendar (Day)
import Data.Typeable (Typeable)
import Safe (headDef, headMay)
import System.Console.Haskeline (runInputT, defaultSettings, setComplete)
import System.Console.Haskeline.Completion
import System.Console.Wizard  
import System.Console.Wizard.Haskeline
import System.IO ( stderr, hPutStr, hPutStrLn )
import Text.ParserCombinators.Parsec hiding (Line)
import Text.Printf

import Hledger
import Hledger.Cli.Options
import Hledger.Cli.Register (postingsReportAsText)

-- | State used while entering transactions.
data EntryState = EntryState {
   esOpts               :: CliOpts           -- ^ command line options
  ,esArgs               :: [String]          -- ^ command line arguments remaining to be used as defaults
  ,esToday              :: Day               -- ^ today's date
  ,esDefDate            :: Day               -- ^ the default date for next transaction
  ,esJournal            :: Journal           -- ^ the journal we are adding to
  ,esSimilarTransaction :: Maybe Transaction -- ^ the most similar historical txn
  ,esPostings           :: [Posting]         -- ^ postings entered so far in the current txn
  } deriving (Show,Typeable)

defEntryState = EntryState {
   esOpts               = defcliopts
  ,esArgs               = []
  ,esToday              = nulldate
  ,esDefDate            = nulldate
  ,esJournal            = nulljournal
  ,esSimilarTransaction = Nothing
  ,esPostings           = []
}

data RestartTransactionException = RestartTransactionException deriving (Typeable,Show)
instance Exception RestartTransactionException

-- data ShowHelpException = ShowHelpException deriving (Typeable,Show)
-- instance Exception ShowHelpException

-- | Read multiple transactions from the console, prompting for each
-- field, and append them to the journal file.  If the journal came
-- from stdin, this command has no effect.
add :: CliOpts -> Journal -> IO ()
add opts j
    | journalFilePath j == "-" = return ()
    | otherwise = do
        hPrintf stderr "Adding transactions to journal file %s\n" (journalFilePath j)
        showHelp
        today <- getCurrentDay
        let es = defEntryState{esOpts=opts
                              ,esArgs=map stripquotes $ listofstringopt "args" $ rawopts_ opts
                              ,esToday=today
                              ,esDefDate=today
                              ,esJournal=j
                              }
        getAndAddTransactions es `E.catch` (\(_::UnexpectedEOF) -> putStr "")

showHelp = hPutStr stderr $ unlines [
     "Any command line arguments will be used as defaults."
    ,"Use tab key to complete, readline keys to edit, enter to accept defaults."
    ,"An optional (CODE) may follow transaction dates."
    ,"An optional ; COMMENT may follow descriptions or amounts."
    ,"If you make a mistake, enter < at any prompt to restart the transaction."
    ,"To end a transaction, enter . when prompted."
    ,"To quit, enter . at a date prompt or press control-d or control-c."
    ]

-- | Loop reading transactions from the console, prompting, validating
-- and appending each one to the journal file, until end of input or
-- ctrl-c (then raise an EOF exception).  If provided, command-line
-- arguments are used as defaults; otherwise defaults come from the
-- most similar recent transaction in the journal.
getAndAddTransactions :: EntryState -> IO ()
getAndAddTransactions es@EntryState{..} = (do
  mt <- runInputT (setComplete noCompletion defaultSettings) (run $ haskeline $ confirmedTransactionWizard es)
  case mt of
    Nothing -> fail "urk ?"
    Just t -> do
      j <- if debug_ esOpts > 0
           then do hPrintf stderr "Skipping journal add due to debug mode.\n"
                   return esJournal
           else do j' <- journalAddTransaction esJournal esOpts t
                   hPrintf stderr "Saved.\n"
                   return j'
      hPrintf stderr "Starting the next transaction (. or ctrl-D/ctrl-C to quit)\n"
      getAndAddTransactions es{esJournal=j, esDefDate=tdate t}
  )
  `E.catch` (\(_::RestartTransactionException) ->
                 hPrintf stderr "Restarting this transaction.\n" >> getAndAddTransactions es)

-- confirmedTransactionWizard :: (ArbitraryIO :<: b, OutputLn :<: b, Line :<: b) => EntryState -> Wizard b Transaction
-- confirmedTransactionWizard :: EntryState -> Wizard Haskeline Transaction
confirmedTransactionWizard es@EntryState{..} = do
  t <- transactionWizard es
  -- liftIO $ hPrintf stderr {- "Transaction entered:\n%s" -} (show t)
  output $ show t
  y <- let def = "y" in
       retryMsg "Please enter y or n." $ 
        parser ((fmap ('y' ==)) . headMay . map toLower . strip) $ 
        defaultTo' def $ nonEmpty $ 
        maybeRestartTransaction $
        line $ green $ printf "Save this transaction to the journal ?%s: " (showDefault def)
  if y then return t else throw RestartTransactionException

transactionWizard es@EntryState{..} = do
  (date,code)    <- dateAndCodeWizard es
  let es1@EntryState{esArgs=args1} = es{esArgs=drop 1 esArgs, esDefDate=date}
  (desc,comment) <- descriptionAndCommentWizard es1
  let mbaset = similarTransaction es1 desc
  when (isJust mbaset) $ liftIO $ hPrintf stderr "Using this similar transaction for defaults:\n%s" (show $ fromJust mbaset)
  let es2 = es1{esArgs=drop 1 args1, esSimilarTransaction=mbaset}
      balancedPostingsWizard = do
        ps <- postingsWizard es2{esPostings=[]}
        let t = nulltransaction{tdate=date
                               ,tstatus=False
                               ,tcode=code
                               ,tdescription=desc
                               ,tcomment=comment
                               ,tpostings=ps
                               }
        case balanceTransaction Nothing t of -- imprecise balancing (?)
          Right t' -> return t'
          Left err -> liftIO (hPutStrLn stderr $ "\n" ++ (capitalize err) ++ "please re-enter.") >> balancedPostingsWizard
  balancedPostingsWizard

-- Identify the closest recent match for this description in past transactions.
similarTransaction :: EntryState -> String -> Maybe Transaction
similarTransaction EntryState{..} desc =
  let q = queryFromOptsOnly esToday $ reportopts_ esOpts
      historymatches = transactionsSimilarTo esJournal q desc
      bestmatch | null historymatches = Nothing
                | otherwise           = Just $ snd $ head historymatches
  in bestmatch

dateAndCodeWizard EntryState{..} = do
  let def = headDef (showDate esDefDate) esArgs
  retryMsg "A valid hledger smart date is required. Eg: 2014/2/14, 14, yesterday." $ 
   parser (parseSmartDateAndCode esToday) $ 
   withCompletion (dateCompleter def) $
   defaultTo' def $ nonEmpty $ 
   maybeExit $
   maybeRestartTransaction $
   -- maybeShowHelp $
   line $ green $ printf "Date%s: " (showDefault def)
    where
      parseSmartDateAndCode refdate s = either (const Nothing) (\(d,c) -> return (fixSmartDate refdate d, c)) edc
          where
            edc = parseWithCtx nullctx dateandcodep $ lowercase s
            dateandcodep = do
                d <- smartdate
                c <- optionMaybe codep
                many spacenonewline
                eof
                return (d, fromMaybe "" c)
      -- defday = fixSmartDate today $ fromparse $ (parse smartdate "" . lowercase) defdate
      -- datestr = showDate $ fixSmartDate defday smtdate

descriptionAndCommentWizard EntryState{..} = do
  let def = headDef "" esArgs
  s <- withCompletion (descriptionCompleter esJournal def) $
       defaultTo' def $ nonEmpty $ 
       maybeRestartTransaction $
       line $ green $ printf "Description%s: " (showDefault def)
  let (desc,comment) = (strip a, strip $ dropWhile (==';') b) where (a,b) = break (==';') s
  return (desc,comment)

postingsWizard es@EntryState{..} = do
  mp <- postingWizard es
  case mp of Nothing -> return esPostings
             Just p  -> postingsWizard es{esArgs=drop 2 esArgs, esPostings=esPostings++[p]}

postingWizard es@EntryState{..} = do
  acct <- accountWizard es
  if acct == "."
  then case (esPostings, postingsBalanced esPostings) of
         ([],_)    -> liftIO (hPutStrLn stderr "Please enter some postings first.") >> postingWizard es
         (_,False) -> liftIO (hPutStrLn stderr "Please enter more postings to balance the transaction.") >> postingWizard es
         (_,True)  -> return Nothing
  else do
    let es1 = es{esArgs=drop 1 esArgs}
    (amt,comment)  <- amountAndCommentWizard es1
    return $ Just nullposting{paccount=stripbrackets acct
                             ,pamount=mixed amt
                             ,pcomment=comment
                             ,ptype=accountNamePostingType acct
                             }

postingsBalanced :: [Posting] -> Bool
postingsBalanced ps = isRight $ balanceTransaction Nothing nulltransaction{tpostings=ps}

accountWizard EntryState{..} = do
  let pnum = length esPostings + 1
      historicalp = maybe Nothing (Just . (!! (pnum-1)) . (++ (repeat nullposting)) . tpostings) esSimilarTransaction
      historicalacct = case historicalp of Just p  -> showAccountName Nothing (ptype p) (paccount p)
                                           Nothing -> ""
      def = headDef historicalacct esArgs
  retryMsg "A valid hledger account name is required. Eg: assets:cash, expenses:food:eating out." $
   parser parseAccount $
   withCompletion (accountCompleter esJournal def) $
   defaultTo' def $ nonEmpty $ 
   maybeRestartTransaction $
   line $ green $ printf "Account %d%s%s: " pnum endmsg (showDefault def)
    where
      canfinish = not (null esPostings) && postingsBalanced esPostings
      endmsg | canfinish = " (or . to finish this transaction)"
             | otherwise = ""
      parseAccount s = either (const Nothing) validateAccount $ parseWithCtx (jContext esJournal) accountnamep s
      validateAccount s | null s                  = Nothing
                        | no_new_accounts_ esOpts && not (s `elem` journalAccountNames esJournal) = Nothing
                        | otherwise               = Just s

amountAndCommentWizard EntryState{..} = do
  let pnum = length esPostings + 1
      (mhistoricalp,followedhistoricalsofar) =
          case esSimilarTransaction of
            Nothing                        -> (Nothing,False)
            Just Transaction{tpostings=ps} -> (if length ps >= pnum then Just (ps !! (pnum-1)) else Nothing
                                              ,all (\(a,b) -> pamount a == pamount b) $ zip esPostings ps)
      def = case (esArgs, mhistoricalp, followedhistoricalsofar) of
              (d:_,_,_)                                             -> d
              (_,Just hp,True)                                      -> showamt $ pamount hp
              _  | pnum > 1 && not (isZeroMixedAmount balancingamt) -> showamt balancingamt
              _                                                     -> ""
  retryMsg "A valid hledger amount is required. Eg: 1, $2, 3 EUR, \"4 red apples\"." $
   parser parseAmountAndComment $ 
   withCompletion (amountCompleter def) $
   defaultTo' def $ nonEmpty $ 
   maybeRestartTransaction $
   line $ green $ printf "Amount  %d%s: " pnum (showDefault def)
    where  
      parseAmountAndComment = either (const Nothing) Just . parseWithCtx (jContext esJournal) amountandcommentp
      amountandcommentp = do
        a <- amountp
        many spacenonewline
        c <- fromMaybe "" `fmap` optionMaybe (char ';' >> many anyChar)
        -- eof
        return (a,c)
      balancingamt = negate $ sum $ map pamount realps where realps = filter isReal esPostings
      showamt = showMixedAmountWithPrecision
                  -- what should this be ?
                  -- 1 maxprecision (show all decimal places or none) ?
                  -- 2 maxprecisionwithpoint (show all decimal places or .0 - avoids some but not all confusion with thousands separators) ?
                  -- 3 canonical precision for this commodity in the journal ?
                  -- 4 maximum precision entered so far in this transaction ?
                  -- 5 3 or 4, whichever would show the most decimal places ?
                  -- I think 1 or 4, whichever would show the most decimal places
                  maxprecisionwithpoint
  --
  -- let -- (amt,comment) = (strip a, strip $ dropWhile (==';') b) where (a,b) = break (==';') amtcmt
      -- a           = fromparse $ runParser (amountp <|> return missingamt) (jContext esJournal) "" amt
  --     awithoutctx = fromparse $ runParser (amountp <|> return missingamt) nullctx              "" amt
  --     defamtaccepted = Just (showAmount a) == mdefamt
  --     es2 = if defamtaccepted then es1 else es1{esHistoricalPostings=Nothing}
  --     mdefaultcommodityapplied = if acommodity a == acommodity awithoutctx then Nothing else Just $ acommodity a
  -- when (isJust mdefaultcommodityapplied) $
  --      liftIO $ hPutStrLn stderr $ printf "using default commodity (%s)" (fromJust mdefaultcommodityapplied)

maybeExit = parser (\s -> if s=="." then throw UnexpectedEOF else Just s)

maybeRestartTransaction = parser (\s -> if s=="<" then throw RestartTransactionException else Just s)

-- maybeShowHelp :: Wizard Haskeline String -> Wizard Haskeline String
-- maybeShowHelp wizard = maybe (liftIO showHelp >> wizard) return $ 
--                        parser (\s -> if s=="?" then Nothing else Just s) wizard

simpleCompletion' s = (simpleCompletion s){isFinished=False}

dateCompleter :: String -> CompletionFunc IO
dateCompleter def = completeWord Nothing "" f
    where
      f "" = return [simpleCompletion' def]
      f s  = return $ map simpleCompletion' $ filter (s `isPrefixOf`) cs
      cs = ["today","tomorrow","yesterday"]

descriptionCompleter j def = completeWord Nothing "" f
    where
      f "" = return [simpleCompletion' def]
      f s  = return $ map simpleCompletion' $ filter (s `isPrefixOf`) cs
      -- f s  = return $ map simpleCompletion' $ filter ((lowercase s `isPrefixOf`) . lowercase) cs
      cs = journalDescriptions j

accountCompleter j def = completeWord Nothing "" f
    where
      f "" = return [simpleCompletion' def]
      f s  = return $ map simpleCompletion' $ filter (s `isPrefixOf`) cs
      cs = journalAccountNamesUsed j

amountCompleter def = completeWord Nothing "" f
    where
      f "" = return [simpleCompletion' def]
      f _  = return []

--------------------------------------------------------------------------------

-- utilities

defaultTo' = flip defaultTo

withCompletion f = withSettings (setComplete f defaultSettings)

green s = "\ESC[1;32m\STX"++s++"\ESC[0m\STX"

showDefault "" = ""
showDefault s = " [" ++ s ++ "]"

-- | Append this transaction to the journal's file and transaction list.
journalAddTransaction :: Journal -> CliOpts -> Transaction -> IO Journal
journalAddTransaction j@Journal{jtxns=ts} opts t = do
  let f = journalFilePath j
  appendToJournalFileOrStdout f $ showTransaction t
  when (debug_ opts > 0) $ do
    putStrLn $ printf "\nAdded transaction to %s:" f
    putStrLn =<< registerFromString (show t)
  return j{jtxns=ts++[t]}

-- | Append a string, typically one or more transactions, to a journal
-- file, or if the file is "-", dump it to stdout.  Tries to avoid
-- excess whitespace.
appendToJournalFileOrStdout :: FilePath -> String -> IO ()
appendToJournalFileOrStdout f s
  | f == "-"  = putStr s'
  | otherwise = appendFile f s'
  where s' = "\n" ++ ensureOneNewlineTerminated s

-- | Replace a string's 0 or more terminating newlines with exactly one.
ensureOneNewlineTerminated :: String -> String
ensureOneNewlineTerminated = (++"\n") . reverse . dropWhile (=='\n') . reverse

-- | Convert a string of journal data into a register report.
registerFromString :: String -> IO String
registerFromString s = do
  d <- getCurrentDay
  j <- readJournal' s
  return $ postingsReportAsText opts $ postingsReport ropts (queryFromOpts d ropts) j
      where
        ropts = defreportopts{empty_=True}
        opts = defcliopts{reportopts_=ropts}

capitalize :: String -> String
capitalize "" = ""
capitalize (c:cs) = toUpper c : cs

-- Find the most similar and recent transactions matching the given transaction description and report query.
-- Transactions are listed with their "relevancy" score, most relevant first.
transactionsSimilarTo :: Journal -> Query -> String -> [(Double,Transaction)]
transactionsSimilarTo j q desc =
    sortBy compareRelevanceAndRecency
               $ filter ((> threshold).fst)
               [(compareDescriptions desc $ tdescription t, t) | t <- ts]
    where
      compareRelevanceAndRecency (n1,t1) (n2,t2) = compare (n2,tdate t2) (n1,tdate t1)
      ts = filter (q `matchesTransaction`) $ jtxns j
      threshold = 0

compareDescriptions :: [Char] -> [Char] -> Double
compareDescriptions s t = compareStrings s' t'
    where s' = simplify s
          t' = simplify t
          simplify = filter (not . (`elem` "0123456789"))

-- | Return a similarity measure, from 0 to 1, for two strings.
-- This is Simon White's letter pairs algorithm from
-- http://www.catalysoft.com/articles/StrikeAMatch.html
-- with a modification for short strings.
compareStrings :: String -> String -> Double
compareStrings "" "" = 1
compareStrings (_:[]) "" = 0
compareStrings "" (_:[]) = 0
compareStrings (a:[]) (b:[]) = if toUpper a == toUpper b then 1 else 0
compareStrings s1 s2 = 2.0 * fromIntegral i / fromIntegral u
    where
      i = length $ intersect pairs1 pairs2
      u = length pairs1 + length pairs2
      pairs1 = wordLetterPairs $ uppercase s1
      pairs2 = wordLetterPairs $ uppercase s2

wordLetterPairs = concatMap letterPairs . words

letterPairs (a:b:rest) = [a,b] : letterPairs (b:rest)
letterPairs _ = []
