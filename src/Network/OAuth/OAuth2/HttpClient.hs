{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE OverloadedStrings  #-}

-- | A simple http client to request OAuth2 tokens and several utils.

module Network.OAuth.OAuth2.HttpClient where

import           Control.Monad                 (liftM)
import           Data.Aeson
import qualified Data.ByteString.Char8         as BS
import qualified Data.ByteString.Lazy.Char8    as BSL
import           Data.Maybe
import           Network.HTTP.Conduit
import qualified Network.HTTP.Types            as HT

import           Network.OAuth.OAuth2.Internal

--------------------------------------------------
-- * Retrieve access token
--------------------------------------------------

-- | Request (via POST method) "Access Token".
--
--
fetchAccessToken :: OAuth2                           -- ^ OAuth Data
                   -> BS.ByteString                  -- ^ Authentication code gained after authorization
                   -> IO (OAuth2Result AccessToken)  -- ^ Access Token
fetchAccessToken oa code = doJSONPostRequest uri body
                           where (uri, body) = accessTokenUrl oa code


-- | Request the "Refresh Token".
fetchRefreshToken :: OAuth2                          -- ^ OAuth context
                     -> BS.ByteString                -- ^ refresh token gained after authorization
                     -> IO (OAuth2Result AccessToken)
fetchRefreshToken oa rtoken = doJSONPostRequest uri body
                              where (uri, body) = refreshAccessTokenUrl oa rtoken


-- | Conduct post request and return response as JSON.
doJSONPostRequest :: FromJSON a
                  => URI                                 -- ^ The URL
                  -> PostBody                            -- ^ request body
                  -> IO (OAuth2Result a)                 -- ^ Response as ByteString
doJSONPostRequest uri body = liftM parseResponseJSON (doSimplePostRequest uri body)

-- | Conduct post request.
doSimplePostRequest :: URI                                  -- ^ URL
                       -> PostBody                          -- ^ Request body.
                       -> IO (OAuth2Result BSL.ByteString)  -- ^ Response as ByteString
doSimplePostRequest url body = liftM handleResponse go
                               where go = do
                                          req <- parseUrl $ BS.unpack url
                                          let req' = updateRequestHeaders Nothing req
                                          withManager $ httpLbs (urlEncodedBody body req')

--------------------------------------------------
-- * AUTH requests
--------------------------------------------------

-- | Conduct GET request and return response as JSON.
authGetJSON :: FromJSON a
                 => AccessToken
                 -> URI                          -- ^ Full URL
                 -> IO (OAuth2Result a)          -- ^ Response as JSON
authGetJSON t uri = liftM parseResponseJSON $ authGetBS t uri

-- | Conduct GET request.
authGetBS :: AccessToken
             -> URI                               -- ^ URL
             -> IO (OAuth2Result BSL.ByteString)  -- ^ Response as ByteString
authGetBS token url = liftM handleResponse go
                      where go = do
                                 req <- parseUrl $ BS.unpack $ url `appendAccessToken` token
                                 authenticatedRequest token Nothing HT.GET req

-- | Conduct POST request and return response as JSON.
authPostJSON :: FromJSON a
                 => AccessToken
                 -> URI                          -- ^ Full URL
                 -> PostBody
                 -> IO (OAuth2Result a)          -- ^ Response as JSON
authPostJSON t uri pb = liftM parseResponseJSON $ authPostBS t uri pb

-- | Conduct POST request.
authPostBS :: AccessToken
             -> URI                               -- ^ URL
             -> PostBody
             -> IO (OAuth2Result BSL.ByteString)  -- ^ Response as ByteString
authPostBS token url pb = liftM handleResponse go
                          where body = pb ++ accessTokenToParam token
                                go = do
                                    req <- parseUrl $ BS.unpack url
                                    authenticatedRequest token Nothing HT.POST $  urlEncodedBody body req

authPostJSONWithBody :: FromJSON a =>
                        AccessToken
                        -> BS.ByteString
                        -> [(BS.ByteString, BS.ByteString)]
                        -> BS.ByteString
                        -> IO (OAuth2Result a)
authPostJSONWithBody token url pb body = liftM parseResponseJSON $ authPostBSwithBody token url pb body


authPostBSwithBody :: AccessToken
                    -> BS.ByteString
                    -> [(BS.ByteString, BS.ByteString)]
                    -> BS.ByteString
                    -> IO (OAuth2Result BSL.ByteString)
authPostBSwithBody token url pb body = liftM handleResponse go
                          where header = pb ++ accessTokenToParam token
                                body' = RequestBodyBS body
                                go = do
                                    req <- parseUrl $ BS.unpack url
                                    authenticatedRequest token (Just body') HT.POST $ urlEncodedBody header req


-- |Sends a HTTP request including the Authorization header with the specified
--  access token.
--
authenticatedRequest :: AccessToken             -- ^ Authentication token to use
                     -> Maybe RequestBody
                     -> HT.StdMethod                     -- ^ Method to use
                     -> Request        -- ^ Request to perform
                     -> IO (Response BSL.ByteString)
authenticatedRequest token body m r = withManager
                                 $ httpLbs
                                 $ updateRequestBody body . updateRequestHeaders (Just token)
                                 $ setMethod m r
-- { checkStatus = \_ _ _ -> Nothing }

-- | Sets the HTTP method to use
--
setMethod :: HT.StdMethod -> Request -> Request
setMethod m req = req { method = HT.renderStdMethod m }

--------------------------------------------------
-- * Utilities
--------------------------------------------------

-- | Parses a @Response@ to to @OAuth2Result@
--
handleResponse :: Response BSL.ByteString -> OAuth2Result BSL.ByteString
handleResponse rsp =
    if HT.statusCode (responseStatus rsp) == 200
        then Right $ responseBody rsp
        else Left $ BSL.append "Gaining token failed: " (responseBody rsp)

-- | Parses a @OAuth2Result BSL.ByteString@ into @FromJSON a => a@
-- 
parseResponseJSON :: FromJSON a
              => OAuth2Result BSL.ByteString
              -> OAuth2Result a
parseResponseJSON (Left b) = Left b
parseResponseJSON (Right b) = case decode b of
                            Nothing -> Left ("Could not decode JSON" `BSL.append` b)
                            Just x -> Right x

-- | set several header values.
--   + userAgennt : hoauth2
--   + accept     : application/json
--   + authorization : Bearer xxxxx  if AccessToken provided.
-- 
updateRequestHeaders :: Maybe AccessToken -> Request -> Request
updateRequestHeaders t req =
  let extras = [ (HT.hUserAgent, "hoauth2")
               , (HT.hAccept, "application/json") 
               , (HT.hContentType, "application/json") ]
      bearer = [(HT.hAuthorization, "Bearer " `BS.append` accessToken (fromJust t)) | isJust t]
      headers = bearer ++ extras
  in
  req { requestHeaders = headers}

updateRequestBody :: Maybe RequestBody -> Request -> Request
updateRequestBody body req = case body of 
    Just a -> req { requestBody = a }
    _ -> req

