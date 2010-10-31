{-# LANGUAGE RecordWildCards #-}

module Aws.Http
where
  
import           Aws.Util
import           Control.Applicative
import           Control.Monad
import           Data.IORef
import           Data.Time
import           Data.Time.Clock.POSIX
import           Network.Curl
import           Network.URI
import qualified Data.ByteString        as B
import qualified Data.ByteString.Lazy   as L
import qualified Data.ByteString.Unsafe as BU
import qualified Foreign.Marshal.Array  as FMA
import qualified Network.HTTP           as HTTP
  
data Protocol
    = HTTP
    | HTTPS
    deriving (Show)

defaultPort :: Protocol -> Int
defaultPort HTTP = 80
defaultPort HTTPS = 443

-- Note/TODO: Large data: just use files
  
data HttpRequest
    = HttpRequest {
        requestMethod :: HTTP.RequestMethod
      , requestDate :: Maybe UTCTime
      , requestUri :: URI
      , requestPostQuery :: [String]
      , requestBody :: L.ByteString
      }
    deriving (Show)

data HttpResponse
    = HttpResponse {
        responseError :: Maybe HttpError
      , responseStatus :: Int
      , responseBody :: L.ByteString
      }
    deriving (Show)

data HttpError
    = CurlError CurlCode
    | OtherError String
    deriving (Show)

curlRequest :: [CurlOption] -> HttpRequest -> IO HttpResponse
curlRequest otherOptions HttpRequest{..} = parse <$> curlGetResponse_ uriString options
    where uriString = show requestUri
          options = (case requestMethod of
                      HTTP.GET -> [CurlHttpGet True]
                      HTTP.POST -> [CurlPostFields requestPostQuery]
                      _ -> error "HTTP methods other than GET and POST not currently supported") ++
                    (case requestDate of
                       Just d -> [CurlTimeValue . round . utcTimeToPOSIXSeconds $ d]
                       Nothing -> []) ++
                    [
                      CurlHttpHeaders headers
                    , CurlFailOnError False
                    ]
                    ++ otherOptions
          headers = case requestDate of
                      Just d -> ["Date: " ++ fmtRfc822Time d]
                      Nothing -> []
          parse :: CurlResponse_ [(String, String)] L.ByteString -> HttpResponse
          parse CurlResponse{..} = HttpResponse {
                                          responseError = CurlError respCurlCode <$ guard (respCurlCode /= CurlOK)
                                        , responseStatus = respStatus
                                        , responseBody = respBody
                                        }

curlGatherBSL :: IORef L.ByteString -> WriteFunction
curlGatherBSL r = gatherOutput_ $ \s -> do
                    bs <- L.fromChunks . return <$> B.packCStringLen s
                    modifyIORef r (`L.append` bs)

curlCallbackWriteBS :: (B.ByteString -> IO ()) -> WriteFunction
curlCallbackWriteBS f = gatherOutput_ (B.packCStringLen >=> f)

curlCallbackWriteBSL :: (L.ByteString -> IO ()) -> WriteFunction
curlCallbackWriteBSL f = curlCallbackWriteBS (f . L.fromChunks . return)

curlCallbackReadBS :: IO (Maybe B.ByteString) -> IO ReadFunction
curlCallbackReadBS next = do
      rest <- newIORef Nothing
      return $ \ptr width count _ -> do
                                 let sz = fromIntegral $ width * count
                                 update rest
                                 r <- readIORef rest
                                 case r of
                                   Nothing -> return Nothing
                                   Just bs -> let (a, b) = B.splitAt sz bs
                                                  l = B.length a
                                              in do
                                                BU.unsafeUseAsCString a (\src -> FMA.copyArray ptr src l)
                                                writeIORef rest (Just b)
                                                return (Just $ fromIntegral l)
    where
      update :: IORef (Maybe B.ByteString) -> IO ()
      update rest = do
        r <- normalise <$> readIORef rest
        r' <- case r of
          Nothing -> next
          x -> return x
        writeIORef rest r'
      
      normalise :: Maybe B.ByteString -> Maybe B.ByteString
      normalise Nothing = Nothing
      normalise (Just bs) | B.null bs = Nothing
                          | otherwise = Just bs
