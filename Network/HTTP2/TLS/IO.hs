{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.HTTP2.TLS.IO where

import Control.Monad (void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Network.Socket
import Network.Socket.BufferPool
import qualified Network.Socket.ByteString as NSB
import Network.TLS hiding (HostName)
import System.IO.Error (isEOFError)
import qualified System.TimeManager as T
import qualified UnliftIO.Exception as E

import Network.HTTP2.TLS.Settings

----------------------------------------------------------------

-- HTTP2: confReadN == recvTLS
-- TLS:   recvData  == contextRecv == backendRecv

----------------------------------------------------------------

mkRecvTCP :: Settings -> Socket -> IO (IO ByteString)
mkRecvTCP Settings{..} sock = do
    pool <- newBufferPool settingReadBufferLowerLimit settingReadBufferSize
    return $ receive sock pool

sendTCP :: Socket -> ByteString -> IO ()
sendTCP sock = NSB.sendAll sock

----------------------------------------------------------------

data IOBackend = IOBackend
    { send :: ByteString -> IO ()
    , sendMany :: [ByteString] -> IO ()
    , recv :: IO ByteString
    }

timeoutIOBackend :: T.Handle -> Int -> IOBackend -> IOBackend
timeoutIOBackend th slowloris IOBackend{..} =
    IOBackend send' sendMany' recv'
  where
    send' bs = send bs >> T.tickle th
    sendMany' bss = sendMany bss >> T.tickle th
    recv' = do
        bs <- recv
        when (BS.length bs > slowloris) $ T.tickle th
        return bs

tlsIOBackend :: Context -> IOBackend
tlsIOBackend ctx =
    IOBackend
        { send = sendTLS ctx
        , sendMany = sendManyTLS ctx
        , recv = recvTLS ctx
        }

tcpIOBackend :: Settings -> Socket -> IO IOBackend
tcpIOBackend settings sock = do
    recv' <- mkRecvTCP settings sock
    return $
        IOBackend
            { send = void . NSB.send sock
            , sendMany = \_ -> return ()
            , recv = recv'
            }

----------------------------------------------------------------

sendTLS :: Context -> ByteString -> IO ()
sendTLS ctx = sendData ctx . LBS.fromStrict

sendManyTLS :: Context -> [ByteString] -> IO ()
sendManyTLS ctx = sendData ctx . LBS.fromChunks

-- TLS version of recv (decrypting) without a cache.
recvTLS :: Context -> IO ByteString
recvTLS ctx = E.handle onEOF $ recvData ctx
  where
    onEOF e
        | Just Error_EOF <- E.fromException e = return ""
        | Just ioe <- E.fromException e, isEOFError ioe = return ""
        | otherwise = E.throwIO e

----------------------------------------------------------------

mkBackend :: Settings -> Socket -> IO Backend
mkBackend settings sock = do
    let send' = sendTCP sock
    recv' <- mkRecvTCP settings sock
    recvN <- makeRecvN "" recv'
    return
        Backend
            { backendFlush = return ()
            , backendClose =
                gracefulClose sock 5000 `E.catch` \(E.SomeException _) -> return ()
            , backendSend = send'
            , backendRecv = recvN
            }
