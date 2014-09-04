{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE OverloadedStrings  #-}

-- |Conduits for serialising and deserialising IRC messages.
module Network.IRC.Conduit
    ( -- *Type synonyms
      ChannelName
    , NickName
    , ServerName
    , Reason
    , IsModeSet
    , ModeFlag
    , ModeArg
    , NumericArg
    , Target
    , IrcEvent
    , IrcSource
    , IrcMessage

    -- *Messages
    , Event(..)
    , Source(..)
    , Message(..)

    -- *Conduits
    , ircDecoder
    , ircEncoder
    , floodProtector

    -- *Utilities
    , ircClient
    , ircTLSClient
    , ircWithConn
    , rawMessage
    , toByteString
    ) where

import Control.Applicative      ((*>))
import Control.Arrow            ((&&&))
import Control.Concurrent       (newMVar, takeMVar, putMVar, threadDelay)
import Control.Concurrent.Async (Concurrently(..))
import Control.Monad            (when)
import Control.Monad.IO.Class   (MonadIO, liftIO)
import Data.ByteString          (ByteString, isSuffixOf)
import Data.Conduit             (Conduit, Consumer, Producer, (=$), ($$), (=$=), await, awaitForever, yield)
import Data.Conduit.Network     (AppData, clientSettings, runTCPClient, appSource, appSink)
import Data.Conduit.Network.TLS (tlsClientConfig, runTLSClient)
import Data.Monoid              ((<>))
import Data.Time.Clock          (NominalDiffTime, getCurrentTime, addUTCTime, diffUTCTime)
import Network.IRC.Conduit.Internal
import System.IO.Error          (catchIOError)

import qualified Data.ByteString as B

-- *Conduits

-- |A conduit which takes as input bytestrings representing encoded
-- IRC messages, and decodes them to events.
ircDecoder :: Monad m => Conduit ByteString m IrcEvent
ircDecoder = chunked =$= awaitForever (yield . decode)

-- |Split up incoming bytestrings into new lines.
chunked :: Monad m => Conduit ByteString m ByteString
chunked = chunked' ""
  where
    chunked' leftover = do
      -- Wait for a value from upstream
      val <- await

      case val of
        Just val' ->
          let
            -- Split on '\n's, removing any stray '\r's (line endings
            -- are usually '\r\n's, but this isn't certain).
            bytes    = B.filter (/=0o015) $ leftover <> val'
            splitted = B.split 0o012 bytes

            -- If the last chunk ends with a '\n', then we have a
            -- complete message at the end, and can yield it
            -- immediately. Otherwise, store the partial message to
            -- prepend to the next bytestring received.
            (toyield, remainder)
              | "\n" `isSuffixOf` bytes = (splitted, "")
              | otherwise = init &&& last $ splitted

          in do
            -- Yield all complete and nonempty messages, and loop.
            mapM_ yield $ filter (not . B.null) toyield
            chunked' remainder

        Nothing -> return ()

-- |Throw an IO exception when the upstream conduit is closed.
exceptionalConduit :: MonadIO m => Conduit a m a
exceptionalConduit = do
  val <- await
  case val of
    Just x  -> yield x >> exceptionalConduit
    Nothing -> liftIO . ioError $ userError "Upstream source closed."

-- |A conduit which takes as input irc messages, and produces as
-- output the encoded bytestring representation.
ircEncoder :: Monad m => Conduit IrcMessage m ByteString
ircEncoder = awaitForever (yield . (<>"\r\n") . encode)

-- |A conduit which rate limits output sent downstream. Awaiting on
-- this conduit will block, even if there is output ready, until the
-- time limit has passed.
floodProtector :: MonadIO m
               => NominalDiffTime
               -- ^The minimum time between sending adjacent messages.
               -> IO (Conduit a m a)
floodProtector delay = do
  now  <- getCurrentTime
  mvar <- newMVar now

  return $ conduit mvar

  where conduit mvar = awaitForever $ \val -> do
          -- Block until the delay has passed
          liftIO $ do
            lastT <- takeMVar mvar
            now   <- getCurrentTime

            let next = addUTCTime delay lastT

            when (next < now) $
              threadDelay . ceiling $ 1000000 * diffUTCTime next now

          -- Update the time
          liftIO $ do
            now' <- getCurrentTime
            putMVar mvar now'

          -- Send the value downstream
          yield val

-- *Utilities

-- |Connect to a network server, without TLS, and concurrently run the
-- producer and consumer.
ircClient :: Int
          -- ^The port number
          -> ByteString
          -- ^The hostname
          -> IO ()
          -- ^Any initialisation work (started concurrently with the
          -- producer and consumer)
          -> Consumer IrcEvent IO ()
          -- ^The consumer of irc events
          -> Producer IO IrcMessage
          -- ^The producer of irc messages
          -> IO ()
ircClient = ircWithConn clientSettings runTCPClient

-- |Like 'ircClient', but with TLS.
ircTLSClient :: Int -> ByteString -> IO () -> Consumer IrcEvent IO () -> Producer IO IrcMessage -> IO ()
ircTLSClient = ircWithConn tlsClientConfig runTLSClient

-- |Use the provided network functions to connect to an IRC network
-- and run the conduits.
ircWithConn :: (Int -> ByteString -> config)
            -- ^The configuration constructor
            -> (config -> (AppData -> IO ()) -> IO ())
            -- ^The network connector
            -> Int
            -> ByteString
            -> IO ()
            -> Consumer IrcEvent IO ()
            -> Producer IO IrcMessage
            -> IO ()
ircWithConn mkconf runner port host start cons prod = go `catchIOError` ignore
  where
    -- Start the connection and concurrently run the initialiser,
    -- event consumer, and message sources: terminating as soon as one
    -- throws an exception.
    go = runner (mkconf port host) $ \appdata ->
           runConcurrently $
             Concurrently start *>
             Concurrently (appSource appdata =$= exceptionalConduit $$ ircDecoder =$ cons) *>
             Concurrently (prod $$ ircEncoder =$ appSink appdata)

    -- Ignore all exceptions and just halt.
    ignore _ = return ()

-- |Convert a message to a bytestring
toByteString :: IrcMessage -> ByteString
toByteString = encode
