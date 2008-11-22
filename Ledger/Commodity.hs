{-|

A 'Commodity' is a symbol representing a currency or some other kind of
thing we are tracking, and some settings that tell how to display amounts
of the commodity.  For the moment, commodities also include a hard-coded
conversion rate relative to the dollar.

-}
module Ledger.Commodity
where
import qualified Data.Map as Map
import Ledger.Utils
import Ledger.Types


-- for nullamt, autoamt, etc.
unknown = Commodity {symbol="",side=L,spaced=False,comma=False,precision=0}

-- convenient amount and commodity constructors, for tests etc.

dollar  = Commodity {symbol="$",side=L,spaced=False,comma=False,precision=2}
euro    = Commodity {symbol="EUR",side=L,spaced=False,comma=False,precision=2}
pound   = Commodity {symbol="£",side=L,spaced=False,comma=False,precision=2}
hour    = Commodity {symbol="h",side=R,spaced=False,comma=False,precision=1}

dollars n = Amount dollar n Nothing
euros n   = Amount euro n Nothing
pounds n  = Amount pound n Nothing
hours n   = Amount hour n Nothing

defaultcommodities = [dollar,  euro,  pound, hour, unknown]

defaultcommoditiesmap :: Map.Map String Commodity
defaultcommoditiesmap = Map.fromList [(symbol c :: String, c :: Commodity) | c <- defaultcommodities]

comm :: String -> Commodity
comm symbol = Map.findWithDefault (error "commodity lookup failed") symbol defaultcommoditiesmap

-- | Find the conversion rate between two commodities.
conversionRate :: Commodity -> Commodity -> Double
conversionRate oldc newc = 1

