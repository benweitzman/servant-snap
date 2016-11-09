{-# LANGUAGE CPP                  #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}

#if __GLASGOW_HASKELL__ < 710
{-# LANGUAGE OverlappingInstances #-}
#endif

module Servant.Server.Internal
  ( module Servant.Server.Internal
  , module Servant.Server.Internal.PathInfo
  , module Servant.Server.Internal.Router
  , module Servant.Server.Internal.RoutingApplication
  , module Servant.Server.Internal.ServantErr
  ) where

-------------------------------------------------------------------------------
import           Control.Applicative         ((<$>))
import           Control.Monad.Trans.Class   (lift)
import           Data.Bool                   (bool)
import qualified Data.ByteString.Char8       as B
import qualified Data.ByteString.Lazy        as BL
import           Data.Maybe                  (fromMaybe, mapMaybe)
import           Data.Proxy
import           Data.String                 (fromString)
import           Data.String.Conversions     (cs, (<>))
import           Data.Text                   (Text)
import           GHC.TypeLits                (KnownNat, KnownSymbol, natVal,
                                              symbolVal)
import           Network.HTTP.Types          (HeaderName, Method,
                                              Status(..), parseQueryText,
                                              methodGet, methodHead,
                                              hContentType, hAccept)
import           Web.HttpApiData             (FromHttpApiData,
                                              parseHeaderMaybe,
                                              parseQueryParamMaybe,
                                              parseUrlPieceMaybe,
                                              parseUrlPieces)
import           Snap.Core                   hiding (Headers, Method,
                                              getResponse, headers, route,
                                              method, withRequest)
import           Servant.API                 ((:<|>) (..), (:>), Capture,
                                              CaptureAll, Header,
                                              IsSecure(..), QueryFlag,
                                              QueryParam, QueryParams, Raw,
                                              RemoteHost, ReqBody,
                                              ReflectMethod(..), Verb)
import           Servant.API.ContentTypes    (AcceptHeader (..),
                                              AllCTRender (..),
                                              AllCTUnrender (..), AllMime(..), canHandleAcceptH)
import           Servant.API.ResponseHeaders (Headers, getResponse, GetHeaders,
                                              getHeaders)
-- import           Servant.Common.Text         (FromText, fromText)

import           Servant.Server.Internal.PathInfo
import           Servant.Server.Internal.Router
import           Servant.Server.Internal.RoutingApplication
import           Servant.Server.Internal.ServantErr
import           Servant.Server.Internal.SnapShims

import Snap.Snaplet.Authentication
import Snap.Snaplet.Types


class HasServer api ctx where
  type ServerT ctx api (m :: * -> *) :: *

  route :: (MonadSnap m, AllApply ctx m)
        => Proxy api
        -> Proxy ctx
        -> Delayed ctx m env (ServerT ctx api m)
        -> Router m env

type Server api m = ServerT '[] api m

type family Append a b where
    Append '[] b = b
    Append (a ': as) b = a ': (Append as b)

-- * Instances

-- | A server for @a ':<|>' b@ first tries to match the request against the route
--   represented by @a@ and if it fails tries @b@. You must provide a request
--   handler for each route.
--
-- > type MyApi = "books" :> Get '[JSON] [Book] -- GET /books
-- >         :<|> "books" :> ReqBody Book :> Post '[JSON] Book -- POST /books
-- >
-- > server :: Server MyApi
-- > server = listAllBooks :<|> postBook
-- >   where listAllBooks = ...
-- >         postBook book = ...
instance (HasServer a ctx, HasServer b ctx) => HasServer (a :<|> b) ctx   where

  type ServerT ctx (a :<|> b) m = ServerT ctx a m :<|> ServerT ctx b m

  route Proxy p server = choice (route pa p ((\ (a :<|> _) -> a) <$> server))
                                (route pb p ((\ (_ :<|> b) -> b) <$> server))
    where pa = Proxy :: Proxy a
          pb = Proxy :: Proxy b

captured :: FromHttpApiData a => proxy (Capture sym a) -> Text -> Maybe a
captured _ = parseUrlPieceMaybe

-- | If you use 'Capture' in one of the endpoints for your API,
-- this automatically requires your server-side handler to be a function
-- that takes an argument of the type specified by the 'Capture'.
-- This lets servant worry about getting it from the URL and turning
-- it into a value of the type you specify.
--
-- You can control how it'll be converted from 'Text' to your type
-- by simply providing an instance of 'FromText' for your type.
--
-- Example:
--
-- > type MyApi = "books" :> Capture "isbn" Text :> Get '[JSON] Book
-- >
-- > server :: Server MyApi
-- > server = getBook
-- >   where getBook :: Text -> EitherT ServantErr IO Book
-- >         getBook isbn = ...
instance (FromHttpApiData a, HasServer sublayout ctx)
      => HasServer (Capture capture a :> sublayout) ctx where

  type ServerT ctx (Capture capture a :> sublayout) m =
     a -> ServerT ctx sublayout m

  route Proxy p d =
    CaptureRouter $
      route (Proxy :: Proxy sublayout) p
        (addCapture d $ \ txt -> case parseUrlPieceMaybe txt of
                                   Nothing -> delayedFail err400
                                   Just v  -> return v
        )


instance (FromHttpApiData a, HasServer sublayout ctx)
      => HasServer (CaptureAll capture a :> sublayout) ctx where

  type ServerT ctx (CaptureAll capture a :> sublayout) m =
    [a] -> ServerT ctx sublayout m

  route Proxy p d =
    CaptureAllRouter $
        route (Proxy :: Proxy sublayout) p
              (addCapture d $ \ txts -> case parseUrlPieces txts of
                 Left _  -> delayedFail err400
                 Right v -> return v
              )


allowedMethodHead :: Method -> Request -> Bool
allowedMethodHead method request =
  method == methodGet && unSnapMethod (rqMethod request) == methodHead

allowedMethod :: Method -> Request -> Bool
allowedMethod method request =
  allowedMethodHead method request || unSnapMethod (rqMethod request) == method

processMethodRouter :: Maybe (BL.ByteString, BL.ByteString) -> Status -> Method
                    -> Maybe [(HeaderName, B.ByteString)]
                    -> Request -> RouteResult Response
processMethodRouter handleA status method headers request = case handleA of
  Nothing -> FailFatal err406 -- this should not happen (checked before), so we make it fatal if it does
  Just (contentT, body) -> Route $ responseLBS status hdrs bdy
    where
      bdy = if allowedMethodHead method request then "" else body
      hdrs = (hContentType, cs contentT) : fromMaybe [] headers

methodCheck :: MonadSnap m => Method -> Request -> DelayedM m ()
methodCheck method request
  | allowedMethod method request = return ()
  | otherwise                    = delayedFail err405

-- This has switched between using 'Fail' and 'FailFatal' a number of
-- times. If the 'acceptCheck' is run after the body check (which would
-- be morally right), then we have to set this to 'FailFatal', because
-- the body check is not reversible, and therefore backtracking after the
-- body check is no longer an option. However, we now run the accept
-- check before the body check and can therefore afford to make it
-- recoverable.
acceptCheck :: (AllMime list, MonadSnap m) => Proxy list -> B.ByteString -> DelayedM m ()
acceptCheck proxy accH
  | canHandleAcceptH proxy (AcceptHeader accH) = return ()
  | otherwise                                  = delayedFail err406



methodRouter :: (AllCTRender ctypes a, MonadSnap m, AllApply ctx m)
             => Method -> Proxy ctypes -> Status
             -> Delayed ctx m env (m a)
             -> Router m env -- Request (RoutingApplication m) m
methodRouter method proxy status action = leafRouter route'
  where
    route' env request respond =
          let accH = fromMaybe ct_wildcard $ getHeader hAccept request -- lookup hAccept $ requestHeaders request
          in runAction (action `addMethodCheck` methodCheck method request
                               `addAcceptCheck` acceptCheck proxy accH
                       ) env request respond $ \ output -> do
               let handleA = handleAcceptH proxy (AcceptHeader accH) output
               processMethodRouter handleA status method Nothing request


methodRouterHeaders :: (GetHeaders (Headers h v), AllCTRender ctypes v, MonadSnap m, AllApply ctx m)
                    => Method -> Proxy ctypes -> Status
                    -> Delayed ctx m env (m (Headers h v))
                    -> Router m env -- Request (RoutingApplication m) m
methodRouterHeaders method proxy status action = leafRouter route'
  where
    route' env request respond =
          let accH    = fromMaybe ct_wildcard $ getHeader hAccept request -- lookup hAccept $ requestHeaders request
          in runAction (action `addMethodCheck` methodCheck method request
                               `addAcceptCheck` acceptCheck proxy accH
                       ) env request respond $ \ output -> do
                let headers = getHeaders output
                    handleA = handleAcceptH proxy (AcceptHeader accH) (getResponse output)
                processMethodRouter handleA status method (Just headers) request


instance {-# OVERLAPPABLE #-} (AllCTRender ctypes a,
                               ReflectMethod method,
                               KnownNat status)
  => HasServer (Verb method status ctypes a) ctx where
  type ServerT ctx (Verb method status ctypes  a) m = m a

  route Proxy p = methodRouter method (Proxy :: Proxy ctypes) status
    where method = reflectMethod (Proxy :: Proxy method)
          status = toEnum . fromInteger $ natVal (Proxy :: Proxy status)

instance {-# OVERLAPPABLE #-} (AllCTRender ctypes a,
                               ReflectMethod method,
                               KnownNat status,
                               GetHeaders (Headers h a))
  => HasServer (Verb method status ctypes (Headers h a)) ctx where

  type ServerT ctx (Verb method status ctypes (Headers h a)) m = m (Headers h a)
  route Proxy p = methodRouterHeaders method (Proxy :: Proxy ctypes) status
    where method = reflectMethod (Proxy :: Proxy method)
          status = toEnum . fromInteger $ natVal (Proxy :: Proxy status)



-- | If you use 'Header' in one of the endpoints for your API,
-- this automatically requires your server-side handler to be a function
-- that takes an argument of the type specified by 'Header'.
-- This lets servant worry about extracting it from the request and turning
-- it into a value of the type you specify.
--
-- All it asks is for a 'FromText' instance.
--
-- Example:
--
-- > newtype Referer = Referer Text
-- >   deriving (Eq, Show, FromText, ToText)
-- >
-- >            -- GET /view-my-referer
-- > type MyApi = "view-my-referer" :> Header "Referer" Referer :> Get '[JSON] Referer
-- >
-- > server :: Server MyApi
-- > server = viewReferer
-- >   where viewReferer :: Referer -> EitherT ServantErr IO referer
-- >         viewReferer referer = return referer
instance (KnownSymbol sym, FromHttpApiData a, HasServer sublayout ctx)
      => HasServer (Header sym a :> sublayout) ctx where

  type ServerT ctx (Header sym a :> sublayout) m =
    Maybe a -> ServerT ctx sublayout m

  route Proxy p subserver =
    let mheader req = parseHeaderMaybe =<< getHeader str req
    in  route (Proxy :: Proxy sublayout) p (passToServer subserver mheader)
    where str = fromString $ symbolVal (Proxy :: Proxy sym)


-- | If you use @'QueryParam' "author" Text@ in one of the endpoints for your API,
-- this automatically requires your server-side handler to be a function
-- that takes an argument of type @'Maybe' 'Text'@.
--
-- This lets servant worry about looking it up in the query string
-- and turning it into a value of the type you specify, enclosed
-- in 'Maybe', because it may not be there and servant would then
-- hand you 'Nothing'.
--
-- You can control how it'll be converted from 'Text' to your type
-- by simply providing an instance of 'FromText' for your type.
--
-- Example:
--
-- > type MyApi = "books" :> QueryParam "author" Text :> Get '[JSON] [Book]
-- >
-- > server :: Server MyApi
-- > server = getBooksBy
-- >   where getBooksBy :: Maybe Text -> EitherT ServantErr IO [Book]
-- >         getBooksBy Nothing       = ...return all books...
-- >         getBooksBy (Just author) = ...return books by the given author...
instance (KnownSymbol sym, FromHttpApiData a, HasServer sublayout ctx)
      => HasServer (QueryParam sym a :> sublayout) ctx where

  type ServerT ctx (QueryParam sym a :> sublayout) m =
    Maybe a -> ServerT ctx sublayout m

  route Proxy p subserver =
    let querytext r = parseQueryText $ rqQueryString r
        param r =
          case lookup paramname (querytext r) of
            Nothing       -> Nothing -- param absent from the query string
            Just Nothing  -> Nothing -- param present with no value -> Nothing
            Just (Just v) -> parseQueryParamMaybe v -- if present, we try to convert to
                                        -- the right type
    in route (Proxy :: Proxy sublayout) p (passToServer subserver param)
    where paramname = cs $ symbolVal (Proxy :: Proxy sym)


-- | If you use @'QueryParams' "authors" Text@ in one of the endpoints for your API,
-- this automatically requires your server-side handler to be a function
-- that takes an argument of type @['Text']@.
--
-- This lets servant worry about looking up 0 or more values in the query string
-- associated to @authors@ and turning each of them into a value of
-- the type you specify.
--
-- You can control how the individual values are converted from 'Text' to your type
-- by simply providing an instance of 'FromText' for your type.
--
-- Example:
--
-- > type MyApi = "books" :> QueryParams "authors" Text :> Get '[JSON] [Book]
-- >
-- > server :: Server MyApi
-- > server = getBooksBy
-- >   where getBooksBy :: [Text] -> EitherT ServantErr IO [Book]
-- >         getBooksBy authors = ...return all books by these authors...
instance (KnownSymbol sym, FromHttpApiData a, HasServer sublayout ctx)
      => HasServer (QueryParams sym a :> sublayout) ctx where

  type ServerT ctx (QueryParams sym a :> sublayout) m =
    [a] -> ServerT ctx sublayout m

  route Proxy p subserver =
    let querytext r = parseQueryText $ rqQueryString r
        -- if sym is "foo", we look for query string parameters
        -- named "foo" or "foo[]" and call parseQueryParam on the
        -- corresponding values
        parameters r = filter looksLikeParam (querytext r)
        values r = mapMaybe (convert . snd) (parameters r)
    in  route (Proxy :: Proxy sublayout) p (passToServer subserver values)
    where paramname = cs $ symbolVal (Proxy :: Proxy sym)
          looksLikeParam (name, _) = name == paramname || name == (paramname <> "[]")
          convert Nothing = Nothing
          convert (Just v) = parseQueryParamMaybe v


-- | If you use @'QueryFlag' "published"@ in one of the endpoints for your API,
-- this automatically requires your server-side handler to be a function
-- that takes an argument of type 'Bool'.
--
-- Example:
--
-- > type MyApi = "books" :> QueryFlag "published" :> Get '[JSON] [Book]
-- >
-- > server :: Server MyApi
-- > server = getBooks
-- >   where getBooks :: Bool -> EitherT ServantErr IO [Book]
-- >         getBooks onlyPublished = ...return all books, or only the ones that are already published, depending on the argument...
instance (KnownSymbol sym, HasServer sublayout ctx)
      => HasServer (QueryFlag sym :> sublayout) ctx where

  type ServerT ctx (QueryFlag sym :> sublayout) m =
    Bool -> ServerT ctx sublayout m

  route Proxy p subserver =
    let querytext r = parseQueryText $ rqQueryString r
        param r = case lookup paramname (querytext r) of
          Just Nothing  -> True  -- param is there, with no value
          Just (Just v) -> examine v -- param with a value
          Nothing       -> False -- param not in the query string
    in  route (Proxy :: Proxy sublayout) p (passToServer subserver param)
    where paramname = cs $ symbolVal (Proxy :: Proxy sym)
          examine v | v == "true" || v == "1" || v == "" = True
                    | otherwise = False


-- | Just pass the request to the underlying application and serve its response.
--
-- Example:
--
-- > type MyApi = "images" :> Raw
-- >
-- > server :: Server MyApi
-- > server = serveDirectory "/var/www/images"
instance HasServer Raw ctx where

  type ServerT ctx Raw m = m ()

  route Proxy p rawApplication = RawRouter $ \ env request respond -> do
    r <- runDelayed rawApplication env request
    case r of
      Route app   -> (snapToApplication' app) request (respond . Route)
      Fail a      -> respond $ Fail a
      FailFatal e -> respond $ FailFatal e


-- | If you use 'ReqBody' in one of the endpoints for your API,
-- this automatically requires your server-side handler to be a function
-- that takes an argument of the type specified by 'ReqBody'.
-- The @Content-Type@ header is inspected, and the list provided is used to
-- attempt deserialization. If the request does not have a @Content-Type@
-- header, it is treated as @application/octet-stream@.
-- This lets servant worry about extracting it from the request and turning
-- it into a value of the type you specify.
--
--
-- All it asks is for a 'FromJSON' instance.
--
-- Example:
--
-- > type MyApi = "books" :> ReqBody '[JSON] Book :> Post '[JSON] Book
-- >
-- > server :: Server MyApi
-- > server = postBook
-- >   where postBook :: Book -> EitherT ServantErr IO Book
-- >         postBook book = ...insert into your db...
instance ( AllCTUnrender list a, HasServer sublayout ctx
         ) => HasServer (ReqBody list a :> sublayout) ctx where

  type ServerT ctx (ReqBody list a :> sublayout) m =
    a -> ServerT ctx sublayout m

  route Proxy p subserver =
    route (Proxy :: Proxy sublayout) p (addBodyCheck (subserver ) bodyCheck')
    where
      -- bodyCheck' :: DelayedM m a
      bodyCheck' = do
        req <- lift getRequest
        let contentTypeH = fromMaybe "application/octet-stream" $ getHeader hContentType req
        mrqbody <- handleCTypeH (Proxy :: Proxy list) (cs contentTypeH) <$>
                                 lift (readRequestBody 2147483647) -- Maximum size: 2GB
        case mrqbody of
          Nothing        -> delayedFailFatal err415
          Just (Left e)  -> delayedFailFatal err400 { errBody = cs e }
          Just (Right v) -> return v

data Authenticated (a :: *)


instance (HasServer sublayout '[HasJWTSettings], FromJWT a) => HasServer (Authenticated a :> sublayout) '[HasJWTSettings] where
    type ServerT '[HasJWTSettings] (Authenticated a :> sublayout) m = a -> ServerT '[HasJWTSettings] sublayout m

    route Proxy p subserver =
        route (Proxy :: Proxy sublayout) p (addAuthCheck subserver authCheck')
      where
        -- authCheck' :: DelayedM m a
        authCheck' = do
          req <- lift getRequest
          settings <- lift getJWTSettings
          let (AuthCheck runAuth) = jwtAuthCheck settings
          (x :: AuthResult a) <- lift $ runAuth req
          case x of
            Authenticated val -> return val
            _ -> delayedFail err403

-- | Make sure the incoming request starts with @"/path"@, strip it and
-- pass the rest of the request path to @sublayout@.
instance (KnownSymbol path, HasServer sublayout ctx) => HasServer (path :> sublayout) ctx where

  type ServerT ctx (path :> sublayout) m = ServerT ctx sublayout m

  route Proxy p subserver =
    pathRouter
      (cs (symbolVal proxyPath))
      (route (Proxy :: Proxy sublayout) p subserver)
    where proxyPath = Proxy :: Proxy path


instance HasServer api ctx => HasServer (HttpVersion :> api) ctx where
  type ServerT ctx (HttpVersion :> api) m = HttpVersion -> ServerT ctx api m

  route Proxy p subserver =
    route (Proxy :: Proxy api) p (passToServer subserver rqVersion)


instance HasServer api ctx => HasServer (IsSecure :> api) ctx where
  type ServerT ctx (IsSecure :> api) m = IsSecure -> ServerT ctx api m

  route Proxy p subserver =
    route (Proxy :: Proxy api) p (passToServer subserver (bool NotSecure Secure . rqIsSecure))

instance HasServer api ctx => HasServer (RemoteHost :> api) ctx where
  type ServerT ctx (RemoteHost :> api) m = B.ByteString -> ServerT ctx api m

  route Proxy p subserver =
    route (Proxy :: Proxy api) p (passToServer subserver rqHostName)

ct_wildcard :: B.ByteString
ct_wildcard = "*" <> "/" <> "*" -- Because CPP
