{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Monoid (mconcat)
import Data.Semigroup ((<>))
import Data.Text (Text, unpack)

import Yukibot.Backend
import Yukibot.Backend.IRC

main :: IO ()
main = do
  h <- startBackend (\e -> putStrLn $ "GOT EVENT: " ++ showTextEvent e) ircBackend
  awaitStart h
  sendAction h (Join "##compsoc-uk-anime")
  awaitStop h

showTextEvent :: Event Text Text -> String
showTextEvent (Event h c u msg) = unpack . mconcat $
  [ "[@" <> describeBackend h <> "] "
  , "[in: " <> c <> "] "
  , "[from: " <> u <> "] "
  , msg
  ]
