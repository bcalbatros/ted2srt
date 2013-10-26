{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
module Ted where

import           Control.Exception as E
import           Control.Monad
import           Data.Aeson
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy.Char8 as L8
import           Data.Conduit (($$+-))
import           Data.Conduit.Binary (sinkFile)
import qualified Data.HashMap.Strict as HM
import           Data.Maybe
import           Data.Monoid ((<>))
import           Data.Text (Text)
import           qualified Data.Text as T
import           qualified Data.Text.IO as T
import           GHC.Generics (Generic)
import           Network.HTTP.Conduit
import           System.Directory
import           System.IO
import           Text.HTML.DOM (parseLBS)
import           Text.Printf
import           Text.Regex.Posix ((=~))
import           Text.XML (Name)
import           Text.XML.Cursor (attribute, attributeIs, element, fromDocument,
                                  ($//), (&|), (&//))
import qualified Text.XML.Cursor as XC

data Caption = Caption
    { captions :: [Item]
    } deriving (Generic, Show)

data Item = Item
    { duration          :: Int
    , content           :: String
    , startOfParagraph  :: Bool
    , startTime         :: Int
    } deriving (Generic, Show)

data Talk = Talk 
    { tid               :: Text
    , title             :: Text
    , subLang           :: [(Text, Text)]
    , subName           :: Text
    , subLag            :: Double
    } deriving Show

data FileType = SRT | VTT | TXT
    deriving (Show, Eq)

data Subtitle = Subtitle
    { talkId            :: Text
    , language          :: [Text]
    , filename           :: Text
    , timeLag           :: Double
    , filetype          :: FileType
    } deriving Show

instance FromJSON Caption
instance FromJSON Item

getTalk :: Text -> IO (Maybe Talk)
getTalk uri = E.catch
    (do body <- simpleHttp $ T.unpack uri
        let cursor = fromDocument $ parseLBS body
        return $ Just Talk { tid = talkIdTitle cursor "data-id"
                           , title = talkIdTitle cursor "data-title"
                           , subLang = languageCodes cursor
                           , subName = mediaSlug body
                           , subLag = mediaPad body
                           })
    (\e -> do print (e :: E.SomeException)
              return Nothing)

talkIdTitle :: XC.Cursor -> Name -> Text
talkIdTitle cursor name = attr name
  where
    cur = head $ cursor $// element "div" >=> attributeIs "id" "share_and_save"
    attr name = head $ attribute name cur

{- List in the form of [("English", "en")] -}
languageCodes :: XC.Cursor -> [(Text, Text)]
languageCodes cursor = zip lang code
  where
    lang = cursor $// element "select" 
                  >=> attributeIs "name" "languageCode" 
                  &// element "option" &// XC.content
    code = concat $ cursor $// element "select" 
                           >=> attributeIs "name" "languageCode" 
                           &// element "option"
                           &| attribute "value"

{- File name when saved to local. -}
mediaSlug :: L8.ByteString -> Text
mediaSlug body = T.pack $ last $ last r
  where
    pat = "mediaSlug\":\"([^\"]+)\"" :: String
    r = L8.unpack body =~ pat :: [[String]]

{- Time lag in miliseconds. -}
mediaPad :: L8.ByteString -> Double
mediaPad body = read t * 1000.0
  where
    pat = "mediaPad\":(.+)}" :: String
    r = L8.unpack body =~ pat :: [[String]]
    t = last $ last r

toSub :: Subtitle -> IO (Maybe String)
toSub sub 
    | length lang == 1 = func sub
    | length lang == 2 = do
        pwd <- getCurrentDirectory
        let (s1, s2) = (head lang, last lang)
            path = T.unpack $ T.concat [ T.pack pwd
                                       , dir
                                       , filename sub
                                       , "."
                                       , s1
                                       , "."
                                       , s2
                                       , suffix
                                       ]
        cached <- doesFileExist path
        if cached 
           then return $ Just path
           else do
                p1 <- func sub { language = [s1] }
                p2 <- func sub { language = [s2] }
                case (p1, p2) of
                     (Just p1', Just p2') -> do
                         c1 <- readFile p1'
                         c2 <- readFile p2'
                         let content = unlines $ merge (lines c1) (lines c2)
                         writeFile path content
                         return $ Just path
                     _                    -> return Nothing
  where
    lang = language sub
    (dir, suffix, func) = case filetype sub of
        SRT -> ("/static/srt/", ".srt", oneSub)
        VTT -> ("/static/vtt/", ".vtt", oneSub)
        TXT -> ("/static/txt/", ".txt", oneTxt)

oneSub :: Subtitle -> IO (Maybe String)
oneSub sub = do
    pwd <- getCurrentDirectory
    let path = T.unpack $ T.concat [ T.pack pwd
                                   , dir
                                   , filename sub
                                   , "."
                                   , head $ language sub
                                   , suffix
                                   ]
    cached <- doesFileExist path
    if cached 
       then return $ Just path
       else do
           let url = T.unpack $ "http://www.ted.com/talks/subtitles/id/" 
                     <> talkId sub <> "/lang/" <> head (language sub)
           json <- simpleHttp url
           let res = decode json :: Maybe Caption
           case res of
                Just r -> do
                    h <- openFile path WriteMode
                    when (filetype sub == VTT) (hPutStrLn h "WEBVTT\n")
                    forM_ (zip (captions $ fromJust res) [1,2..]) (ppr h)
                    hClose h
                    return $ Just path
                Nothing -> 
                    return Nothing
  where
    (dir, suffix) = if filetype sub == SRT 
                        then ("/static/srt/", ".srt")
                        else ("/static/vtt/", ".vtt")
    fmt = if filetype sub == SRT
             then "%d\n%02d:%02d:%02d,%03d --> " ++
                  "%02d:%02d:%02d,%03d\n%s\n\n"
             else "%d\n%02d:%02d:%02d.%03d --> " ++
                  "%02d:%02d:%02d.%03d\n%s\n\n"
    ppr h (c,i) = do
        let st = startTime c + floor (timeLag sub)
            sh = st `div` 1000 `div` 3600
            sm = st `div` 1000 `mod` 3600 `div` 60
            ss = st `div` 1000 `mod` 60
            sms = st `mod` 1000
            et = st + duration c
            eh = et `div` 1000 `div` 3600
            em = et `div` 1000 `mod` 3600 `div` 60
            es = et `div` 1000 `mod` 60
            ems = et `mod` 1000
        hPrintf h fmt (i::Int) sh sm ss sms eh em es ems (content c)

oneTxt :: Subtitle -> IO (Maybe String)
oneTxt sub = do
    pwd <- getCurrentDirectory
    let path = T.unpack $ T.concat [ T.pack pwd
                                   , dir
                                   , filename sub
                                   , "."
                                   , head $ language sub
                                   , suffix
                                   ]
    cached <- doesFileExist path
    if cached 
       then return $ Just path
       else do
           let url = T.unpack $ "http://www.ted.com/talks/subtitles/id/" 
                     <> talkId sub <> "/lang/" <> head (language sub)
                     <> "/format/html"
           res <- simpleHttp url
           let cursor = fromDocument $ parseLBS res
               con = cursor $// element "p" &// XC.content
               txt = filter (`notElem` ["\n", "\n\t\t\t\t\t"]) con
               txt' = map (\t -> if t == "\n\t\t\t" then "\n\n" else t)
                          txt
           T.writeFile path $ T.concat txt'
           return $ Just path
  where
    (dir, suffix) = ("/static/txt/", ".txt")

-- | Merge srt files of two language line by line. However,
-- one line in srt_1 may correspond to two lines in srt_2, or vice versa.
merge :: [String] -> [String] -> [String]
merge (a:as) (b:bs) 
    | a == b    = a : merge as bs
    | a == ""   = b : merge (a:as) bs
    | b == ""   = a : merge as (b:bs)
    | otherwise = a : b : merge as bs
merge _      _      = []

responseSize :: Text -> IO Float
responseSize url = E.catch
    (do req <- parseUrl $ T.unpack url
        size <- withManager $ \manager -> do
            res <- http req manager
            let hdrs = responseHeaders res
            responseBody res $$+- return ()
            return $ HM.fromList hdrs HM.! "Content-Length"
        return $ read (B8.unpack size) / 1024 / 1024)
    (\e -> do print (e :: E.SomeException)
              return 0)
