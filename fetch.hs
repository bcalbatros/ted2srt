{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
import           Control.Monad (forM_, void)
import           Data.Aeson (Result(..), fromJSON)
import qualified Data.ByteString.Char8 as C
import qualified Data.HashMap.Strict as M
import           Data.List (zipWith4)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Yaml
import           Database.Persist.Postgresql
import           GHC.Generics (Generic)
import           Network.HTTP.Conduit (simpleHttp)
import           Text.HTML.DOM (parseLBS)
import           Text.XML.Cursor

import Model

data Database = Database 
    { user      :: String
    , password  :: String
    , host      :: String
    , port      :: Int
    , database  :: String
    , poolsize  :: Int
    } deriving (Show, Generic)

instance FromJSON Database

mkConnStr :: Database -> IO C.ByteString
mkConnStr s = return $ C.pack $ "host=" ++ host s ++
                                " dbname=" ++ database s ++
                                " user=" ++ user s ++
                                " password=" ++ password s ++
                                " port=" ++ show (port s)

loadYaml :: String -> IO (M.HashMap Text Value)
loadYaml fp = do
    mval <- decodeFile fp
    case mval of
        Nothing  -> error $ "Invalid YAML file: " ++ show fp
        Just obj -> return obj

parseYaml :: FromJSON a => Text -> M.HashMap Text Value -> a
parseYaml key hm =
    case M.lookup key hm of
        Just val -> case fromJSON val of
                        Success s -> s
                        Error err -> error $ "Falied to parse " 
                                           ++ T.unpack key ++ ": " ++ show err
        Nothing  -> error $ "Failed to load " ++ T.unpack key 
                                              ++ " from config file"
main :: IO ()
main = do
    config <- loadYaml "config/postgresql.yml"
    let db = parseYaml "Production" config :: Database
    connStr <- mkConnStr db
    res <- simpleHttp url
    let cursor = fromDocument $ parseLBS res
        talks = take 20 $ zipWith4 Talk  (parseTids cursor)
                                         (parseTitles cursor)
                                         (parseLinks cursor)
                                         (parsePics cursor)

    withPostgresqlPool connStr (poolsize db) $ \pool ->
        flip runSqlPersistMPool pool $ do
            runMigration migrateAll
            forM_ (reverse talks) $ \t -> insertUnique t

  where
    url = "http://feeds.feedburner.com/tedtalks_video"
    
    -- 105 tids
    parseTids cur = cur $// element "jwplayer:talkId" &// content
    -- 106 titles
    parseTitles cur = tail $ cur $// element "itunes:subtitle" &// content
    -- 105 links
    parseLinks cur = map rewriteUrl $ cur $// element "feedburner:origLink" &// content
    -- 106 thumbnails
    parsePics cur = map smallPic $ tail $ concat $ 
                    cur $// element "media:thumbnail" &| attribute "url"
    
    -- use 240x180.jpg instead of 480x360.jpg  e.g.
    -- http://images.ted.com/images/ted/c58cf2dbb9f8843b91eb2228caf27974b5f428de_480x360.jpg
    smallPic url = (T.reverse. T.drop 11 . T.reverse) url `T.append` "240x180.jpg"
    
    -- substitute ted.com to ted2srt.org  e.g.
    -- http://www.ted.com/talks/marla_spivak_why_bees_are_disappearing.html
    rewriteUrl url = "http://ted2srt.org" `T.append` T.drop 18 url