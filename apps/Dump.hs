{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import           Control.Concurrent (threadDelay)
import           Control.Monad
import           Data.Aeson (ToJSON (..), encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BSL8
import qualified Data.ByteString.Base64 as Base64
import           Data.Function (fix)
import           Data.IORef
import           Data.List
import           Data.List.Split (splitOn)
import           Data.Time.Clock
import           Options.Applicative hiding (action)
import           System.IO
import           Text.Read
import           Text.Show.Pretty

import           Hemokit
import           Hemokit.Start

import           Hemokit.Internal.Utils (withJustM)
import           WebsocketUtils (makeJsonOrShowWSServer, JsonShowable (..))


-- | Arguments for the EEG dump application.
data DumpArgs = DumpArgs
  { emotivArgs  :: EmotivArgs
  , mode        :: DumpMode -- ^ What to dump.
  , realtime    :: Bool     -- ^ In case fromFile is used, throttle to 128 Hz.
  , listDevices :: Bool     -- ^ Do not do anything, print available devices.
  , json        :: Bool     -- ^ Whether to format the output as JSON.
  , serve       :: Maybe (String, Int) -- ^ Serve via websockets on host:port.
  }

-- | Whether to dump raw data, hardware-sent packages, cumulative states,
-- or measurements of device-computer latency.
data DumpMode = Raw | Packets | State | Measure deriving (Eq, Show)


-- | Parser for `DumpArgs`.
dumpArgsParser :: Parser DumpArgs
dumpArgsParser = DumpArgs
  <$> emotivArgsParser
  <*> nullOption
      ( long "mode"
        <> reader parseDumpMode <> value State
        <> help "What to dump. Can be 'raw', 'packets', 'state' or 'measure'" )
  <*> switch
      ( long "realtime"
        <> help "In case --from-file is used, throttle data to 128 Hz like on real device" )
  <*> switch
      ( long "list"
        <> help "Show all available Emotiv devices and exit" )
  <*> switch
      ( long "json"
        <> help "Format output as JSON" )
  <*> (optional . nullOption)
      ( long "serve" <> metavar "HOST:PORT"
        <> eitherReader parseHostPort
        <> help ("Serve output via websockets, e.g. 127.0.0.1:1234 " ++
                 "(port 1234, only localhost) or 0.0.0.0:1234 (all interfaces)") )
  where
    -- TODO https://github.com/pcapriotti/optparse-applicative/issues/48
    eitherReader str2either = reader (either fail return . str2either)


-- | `DumpMode` command line parser.
parseDumpMode :: Monad m => String -> m DumpMode
parseDumpMode s = case s of
  "raw"     -> return Raw
  "packets" -> return Packets
  "state"   -> return State
  "measure" -> return Measure
  _         -> fail "Mode is not valid. Must be 'raw', 'packets', or 'state'."


-- | Parses host and port from a string like "0.0.0.0:1234".
parseHostPort :: String -> Either String (String, Int)
parseHostPort hostPort = case readMaybe portStr of
  Nothing -> Left $ show portStr ++ " is not a valid port number"
  Just p  -> Right (host, p)
  where
    (host, portStr) = splitLast ":" hostPort

    splitLast :: String -> String -> (String, String)
    splitLast sep s = let sp = splitOn sep s -- splitOn never returns []
                       in (intercalate sep (init sp), last sp)


main :: IO ()
main = do
  DumpArgs{ emotivArgs
          , mode
          , realtime
          , listDevices
          , json
          , serve
          } <- parseArgs "Dumps Emotiv data" dumpArgsParser

  if listDevices -- Only list devices
    then getEmotivDevices >>= putStrLn . ("Available devices:\n" ++) . ppShow
    else do

      e'device <- getEmotivDeviceFromArgs emotivArgs

      -- Do we have a device?
      case e'device of
        Left err     -> error err
        Right device -> do

          -- Print to stdout or serve via websockets? Show the datatype or format via JSON?
          -- `output` accepts anything that's JSON-formattable and showable (wrapped in JsonShowable).
          output <- case serve of
            -- TODO use Data.ByteString.Lazy.UTF8.fromString instead of BSL8 to prevent unicode errors
            Nothing           -> return (BSL8.putStrLn . if json then encode else BSL8.pack . show)
            Just (host, port) -> makeJsonOrShowWSServer host port json

          -- For --mode measure: See how long a 0-128 cycle takes
          timeRef <- newIORef =<< getCurrentTime
          countRef <- newIORef (0 :: Int)

          -- Packet loop
          fix $ \loop -> do

            timeBefore <- getCurrentTime

            -- Output accumulative state, device-sent packet, or raw data?

            moreInput <- case mode of
              Packets -> readEmotiv device `withJustM` \(_, packet) ->
                           output (JsonShowable packet)

              State   -> readEmotiv device `withJustM` \(state, _) ->
                           output (JsonShowable state)

              Raw     -> readEmotivRaw device `withJustM` \rawBytes -> do
                           if json then output (JsonShowable rawBytes)
                                   else BS.putStr (emotivRawDataBytes rawBytes)
                           hFlush stdout -- flush so that consuming apps immediately get it

              Measure -> readEmotivRaw device `withJustM` \_ -> do
                           -- When a full cycle is done, print how long it took.
                           count <- readIORef countRef
                           modifyIORef' countRef (+1)
                           when (count == 128) $ do
                             cycleTime <- diffUTCTime <$> getCurrentTime <*> readIORef timeRef
                             output . JsonShowable $ toDoule cycleTime
                             writeIORef countRef 0
                             writeIORef timeRef =<< getCurrentTime
                           where
                             toDoule x = fromRational (toRational x) :: Double


            -- When realtime is on, throttle the reading to 1/129 (a real
            -- device's frequency). But take into the account the time that
            -- we have spent reading from the device.
            when realtime $ do
              timeTaken <- (`diffUTCTime` timeBefore) <$> getCurrentTime
              let delayUs = 1000000 `div` 129 - round (timeTaken * 1000000)
              when (delayUs > 0) $ threadDelay delayUs

            when moreInput loop


-- * JSON instances

instance ToJSON EmotivPacket
instance ToJSON EmotivState

instance ToJSON EmotivRawData where
  toJSON = toJSON . Base64.encode . emotivRawDataBytes

instance ToJSON Sensor where
  toJSON = toJSON . show
