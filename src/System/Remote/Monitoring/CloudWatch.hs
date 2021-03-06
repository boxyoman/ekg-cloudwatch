{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types        #-}
{-# LANGUAGE RecordWildCards   #-}

-- | This module allows you to periodically push your 'ekg' metrics to the
-- Amazon CloudWatch backend. Inspired by the 'ekg-statsd' module.
--
-- To use, run 'forkCloudWatch' with the 'CloudWatchEnv' and metrics 'Store'.
module System.Remote.Monitoring.CloudWatch
  ( CloudWatchId
  , cloudWatchThreadId
  , forkCloudWatch
  , CloudWatchEnv(..)
  , defaultCloudWatchEnv
  ) where

import           Control.Concurrent                   (ThreadId, forkFinally,
                                                       myThreadId, threadDelay)
import           Control.Exception                    (Exception, throwTo,
                                                       toException)
import           Control.Lens                         ((&), (.~), (?~))
import           Control.Monad                        (forM_, guard, unless,
                                                       void)
import qualified Data.ByteString                      as BS
import qualified Data.HashMap.Strict                  as Map
import           Data.Int                             (Int64)
import           Data.List                            (foldl')
import           Data.List.NonEmpty                   (NonEmpty (..))
import           Data.Maybe                           (mapMaybe)
import           Data.Text                            (Text)
import qualified Data.Text                            as Text
import qualified Data.Text.IO                         as Text
import           Data.Time                            (NominalDiffTime)
import           Data.Time.Clock.POSIX                (getPOSIXTime)
import           Data.Traversable                     (for)
import           Network.AWS                          as AWS
import           Network.AWS.CloudWatch               as AWS
import           Network.AWS.Data.ByteString          (toBS)
import           Network.AWS.Data.Query               (toQueryList)
import           System.IO                            (stderr)
import qualified System.Metrics                       as Metrics
import qualified System.Metrics.Distribution.Internal as Distribution

-- | The 'ThreadID' for the 'CloudWatch' process.
newtype CloudWatchId = CloudWatchId
  { cloudWatchThreadId :: ThreadId
  }

-- | The environment for the CloudWatch EKG metric pusher.
data CloudWatchEnv = CloudWatchEnv
  { cweFlushInterval :: !Int
  -- ^ The interval of time to flush, in milliseconds.
  , cweAwsEnv        :: !AWS.Env
  -- ^ The AWS Environment that connects to the CloudWatch services.
  , cweDimensions    :: ![AWS.Dimension]
  -- ^ The extra dimensions to pass for each metric. These can be used to
  -- configure process-level metric information, like "ServerGroup",
  -- "RegionName", "Environment", etc.
  , cweNamespace     :: !Text
  -- ^ The namespace that the service runs in.
  , cweOnError       :: !(forall e. Exception e => e -> IO ())
  -- ^ The function used to handle exceptions coming from 'amazonka' library.
  }

-- | The default 'CloudWatchEnv', requiring an Amazon environment and namespace.
-- Equal to:
-- @
-- 'CloudWatchEnv'
--   { 'cweFlushInterval' = 1000
--   , 'cweAwsEnv' = x
--   , 'cweNamespace' = namespace
--   , 'cweDimensions' = []
--   , 'cweOnError' = 'defaultOnError'
--   }
-- @
defaultCloudWatchEnv :: Text -> AWS.Env -> CloudWatchEnv
defaultCloudWatchEnv namespace x =
  CloudWatchEnv
  { cweFlushInterval = 1000
  , cweAwsEnv = x
  , cweNamespace = namespace
  , cweDimensions = []
  , cweOnError = defaultOnError
  }

-- | The default error handler is to 'show' the exception and log it to
-- @stderr@.
defaultOnError :: Exception e => e -> IO ()
defaultOnError =
  Text.hPutStrLn stderr . Text.pack  . show . toException

-- | Use this if you don't want to do anything with the error.
swallowOnError :: Exception e => e -> IO ()
swallowOnError _ = pure ()

-- | Forks a thread to periodically publish metrics to Amazon's CloudWatch
-- service for the given 'Store'.
forkCloudWatch :: CloudWatchEnv -> Metrics.Store -> IO CloudWatchId
forkCloudWatch env store = do
  me <- myThreadId
  fmap CloudWatchId . forkFinally (loop env store) $ \case
    Left e -> throwTo me e
    Right _ -> pure ()

loop :: CloudWatchEnv -> Metrics.Store -> IO ()
loop env store = do
  start <- time
  sample <- Metrics.sampleAndResetAll store
  flushSample env (sample)
  end <- time
  threadDelay (cweFlushInterval env * 1000 - fromIntegral (end - start))
  loop env store

-- | Microseconds since epoch. Vendored from `ekg-statsd`
time :: IO Int64
time = round . (* 1000000.0) . toDouble <$> getPOSIXTime
  where
    toDouble = realToFrac :: NominalDiffTime -> Double

metricToDatum :: [Dimension] -> Text -> Metrics.Value -> Maybe MetricDatum
metricToDatum dim name val = case val of
  Metrics.Counter n ->
    Just $ mkDatum (mdValue ?~ fromIntegral n)
  Metrics.Gauge n ->
    Just $ mkDatum (mdValue ?~ fromIntegral n)
  Metrics.Distribution d ->
    fmap (\dist -> mkDatum (mdStatisticValues ?~ dist)) (conv d)
  Metrics.Label l ->
    Nothing
  where
    mkDatum k =
      metricDatum name & mdDimensions .~ dim & k

    conv :: Distribution.Stats -> Maybe StatisticSet
    conv Distribution.Stats {..} = do
      guard (count > 0)
      pure (statisticSet (fromIntegral count) sum min max)

weighDatum :: MetricDatum -> Int
weighDatum = BS.length . toBS . toQueryList "member" . (:[])

data SplitAcc = SplitAcc
  { splitAccData :: !(NonEmpty [MetricDatum])
  , splitAccSize :: !Int
  }

splitAt40KB :: [MetricDatum] -> NonEmpty [MetricDatum]
splitAt40KB = splitAccData . foldl' go (SplitAcc ([] :| []) 0)
  where
    limit = 40000
    fudge =  2000
    safety = limit - fudge
    go (SplitAcc (acc :| accs) size) x
      | size + weight >= safety =
          SplitAcc ((x : acc) :| accs) (size + weight)
      | otherwise =
          SplitAcc ([x] :| (acc : accs)) 0
      where
        weight = weighDatum x


flushSample :: CloudWatchEnv -> Metrics.Sample -> IO ()
flushSample CloudWatchEnv{..} = void
  . sendMetric
  . mapMaybe (uncurry (metricToDatum cweDimensions))
  . Map.toList
  where
    sendMetric :: [MetricDatum] -> IO ()
    sendMetric metrics = do
      e <- trying _Error . void . runResourceT . runAWS cweAwsEnv .
        forM_ (splitAt40KB metrics) $ \metrics ->
          unless (null metrics) $
            void (send (putMetricData cweNamespace & pmdMetricData .~ metrics))
      case e of
        Left err -> cweOnError err
        Right _  -> pure ()
