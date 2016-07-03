{-# LANGUAGE DeriveFunctor #-}

-- |
-- Module      : Yukibot.Plugin.LinkInfo.Common
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Stability   : experimental
-- Portability : DeriveFunctor
module Yukibot.Plugin.LinkInfo.Common where

import Control.Monad.Catch (SomeException, catch)
import Data.Aeson (Object, decode')
import Data.ByteString.Lazy (ByteString, toStrict)
import Data.Functor.Contravariant (Contravariant(..))
import Data.Text (Text, pack, strip, unpack)
import Data.Text.Encoding (decodeUtf8')
import Text.XML.HXT.Core ((//>), readString, hasName, getText, runX, withParseHTML, withWarnings, yes, no)
import Text.XML.HXT.TagSoup (withTagSoup)
import qualified Network.HTTP.Simple as W
import Network.URI (URI)

data LinkHandler a = LinkHandler
  { lhPredicate :: a -> Bool
  -- ^ When to apply this handler
  , lhHandler :: a -> IO (LinkInfo Text)
  -- ^ Get link info from a URI
  }

instance Contravariant LinkHandler where
  contramap f lh = LinkHandler
    { lhPredicate = lhPredicate lh . f
    , lhHandler   = lhHandler lh . f
    }

-- | Wrap a 'LinkHandler' with a function that might fail. If the
-- function does fail, the predicate returns false.
contramapMaybe :: (a -> Maybe b) -> LinkHandler b -> LinkHandler a
contramapMaybe f lh = LinkHandler
  { lhPredicate = \a -> case f a of
      Just b -> lhPredicate lh b
      Nothing -> False
  , lhHandler = \a -> case f a of
      Just b -> lhHandler lh b
      Nothing -> pure Failed
  }

data LinkInfo a
  = Title a -- ^ Title to display, in quotes.
  | Info a  -- ^ Information to display verbatim.
  | NoTitle -- ^ The URI has no title.
  | Failed  -- ^ Failed to retrieve the title
  deriving (Eq, Ord, Read, Show, Functor)

-- | Fetch the title of a URI.
fetchTitle :: URI -> IO (Maybe Text)
fetchTitle uri = do
  downloaded <- downloadText uri
  case downloaded of
    Just html -> do
      let doc = readString [ withParseHTML yes
                           , withTagSoup
                           , withWarnings  no
                           ] (unpack html)
      title <- runX $ doc //> hasName "title" //> getText
      pure . Just . strip . pack . toPlainText . concat $ title
    Nothing -> pure Nothing

  where
    toPlainText = dequote . unwords . words

    dequote ('\"':xs) | last xs == '\"' = (init . tail) xs
    dequote xs = xs

-- |Download some JSON over HTTP.
downloadJson :: URI -> IO (Maybe Object)
downloadJson uri = maybe Nothing decode' <$> download uri

-- | Download a file. Assume UTF-8 encoding.
downloadText :: URI -> IO (Maybe Text)
downloadText uri = maybe Nothing decodeUtf8 <$> download uri where
  decodeUtf8 = either (const Nothing) Just . decodeUtf8' . toStrict

-- | Download a file.
download :: URI -> IO (Maybe ByteString)
download uri = fetch `catch` handler where
  fetch = do
    req  <- W.parseRequest (show uri)
    resp <- W.httpLbs req
    pure $ if W.getResponseStatusCode resp == 200
      then Just (W.getResponseBody resp)
      else Nothing

  handler :: SomeException -> IO (Maybe a)
  handler = const $ pure Nothing

-- | Split a string by a character.
wordsWhen :: (Char -> Bool) -> String -> [String]
wordsWhen p s = case dropWhile p s of
  "" -> []
  s' -> let (w, s'') = break p s'
        in w : wordsWhen p s''
