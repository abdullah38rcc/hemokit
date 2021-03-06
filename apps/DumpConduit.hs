{-# LANGUAGE NamedFieldPuns, ExistentialQuantification #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import           Control.Concurrent (threadDelay)
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Aeson (ToJSON (..), encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BSL8
import qualified Data.ByteString.Base64 as Base64
import           Data.Conduit
import qualified Data.Conduit.List as CL
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
import           Hemokit.Conduit
import           Hemokit.Start


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
          let outputSink :: (ToJSON i, Show i) => Sink i IO ()
              outputSink = case serve of
                Nothing           | json      -> asJson $ CL.mapM_ BSL8.putStrLn
                                  | otherwise ->          CL.mapM_ print
                Just (host, port) | json      -> asJson $ websocketSink host port
                                  | otherwise ->          websocketSink host port
                where
                  asJson = mapInput encode (const Nothing)

              throttled = if realtime then ($= throttle) else id

          -- Output accumulative state, device-sent packet, or raw data?
          case mode of
            Packets -> throttled (emotivPackets device) $$ outputSink

            State   -> throttled (emotivStates  device) $$ outputSink

            Raw     -> throttled (rawSource     device) $$ if json then outputSink
                                                                   else CL.mapM_ (putStrBsFlush . emotivRawDataBytes)
            Measure -> throttled (rawSource     device) $= measureConduit $$ outputSink

  where
    putStrBsFlush bs = BS.putStr bs >> hFlush stdout

    measureConduit = do
      -- For --mode measure: See how long a 0-128 cycle takes
      timeRef  <- liftIO $ newIORef =<< getCurrentTime
      countRef <- liftIO $ newIORef (0 :: Int)

      let yieldCyleTimes = do
            -- When a full cycle is done, print how long it took.
            count <- liftIO $ readIORef countRef
                              <* modifyIORef' countRef (+1)
            when (count == 128) $ do
              cycleTime <- liftIO $ diffUTCTime <$> getCurrentTime <*> readIORef timeRef
              yield $ toDoule cycleTime
              liftIO $ do writeIORef countRef 0
                          writeIORef timeRef =<< getCurrentTime
            where
              toDoule x = fromRational (toRational x) :: Double

      awaitForever (const yieldCyleTimes)


-- When realtime is on, throttle the reading to 1/129 (a real
-- device's frequency). But take into the account the time that
-- we have spent reading from the device.
throttle :: (MonadIO m) => Conduit i m i
throttle = fix $ \loop -> do

  timeBefore <- liftIO getCurrentTime
  m'x <- await

  case m'x of
    Nothing -> return ()
    Just x -> do
      timeTaken <- liftIO $ (`diffUTCTime` timeBefore) <$> getCurrentTime
      let delayUs = 1000000 `div` 129 - round (timeTaken * 1000000)
      when (delayUs > 0) $ liftIO $ threadDelay delayUs
      yield x
      loop


-- * JSON instances

instance ToJSON EmotivPacket
instance ToJSON EmotivState

instance ToJSON EmotivRawData where
  toJSON = toJSON . Base64.encode . emotivRawDataBytes

instance ToJSON Sensor where
  toJSON = toJSON . show
