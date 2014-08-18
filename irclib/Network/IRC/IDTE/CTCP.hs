{-# LANGUAGE OverloadedStrings #-}

-- |Functions for encoding and decoding CTCPs.
--
-- CTCP messages are sent as a PRIVMSG or NOTICE, where the first and
-- last characters are 0o001 (SOH), and the escape character is 0o020
-- (DLE).
--
-- Characters are escaped as follows:
--   - 0o000 (NUL) -> 0o020 0o060 ('0')
--   - 0o012 (NL)  -> 0o020 0o156 ('n')
--   - 0o015 (CR)  -> 0o020 0o162 ('r')
--   - 0o020 (DLE) -> 0o020 0o020
--
-- All other appearences of the escape character are errors, and are
-- dropped.
--
-- See http://www.irchelp.org/irchelp/rfc/ctcpspec.html for more
-- details.
module Network.IRC.IDTE.CTCP
    ( CTCPByteString
    , toByteString
    , toCTCP
    , fromCTCP
    , encodeCTCP
    , decodeCTCP
    , isCTCP
    , orCTCP
    ) where

import Prelude hiding (concat, concatMap, head, init, last, length, notElem, tail, unwords)

import Data.ByteString    (ByteString, concat, concatMap, head, init, last, length, notElem, pack, singleton, tail, unpack)
import Data.List          (mapAccumL)
import Data.Maybe         (catMaybes, fromMaybe)
import Data.Text          (Text, splitOn, unwords)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Tuple         (swap)

-- *Types

-- |Type representing a CTCP-encoded string. The constructor is NOT
-- exported, making this safe.
newtype CTCPByteString = CBS { _getUnderlyingByteString :: ByteString }

-- |Get the underlying (encoded) bytestring from a CTCP bytestring.
toByteString :: CTCPByteString -> ByteString
toByteString = _getUnderlyingByteString

-- *Encoding and decoding

-- |Turn a command name and arguments into a CTCP-encoded bytestring
toCTCP :: Text -> [Text] -> CTCPByteString
toCTCP cmd args = encodeCTCP . encodeUtf8 . unwords $ cmd : args

-- |Encode a bytestring with CTCP encoding.
encodeCTCP :: ByteString -> CTCPByteString
encodeCTCP bs = CBS $ concat [ singleton soh
                             , escape bs
                             , singleton soh
                             ]

    where escape = concatMap escape'
          escape' x = case lookup x encodings of
                        -- If there is an encoding, escape it and use
                        -- that.
                        Just x' -> pack [esc, x']

                        -- Otherwise, just return the original
                        -- character.
                        Nothing -> singleton x

-- |Turn a CTCP-encoded bytestring into a command name and arguments
fromCTCP :: CTCPByteString -> (Text, [Text])
fromCTCP bs = case splitOn " " . decodeUtf8 . decodeCTCP $ bs of
                (cmd : args) -> (cmd, args)
                _            -> ("", [])

-- |Decode a CTCP-encoded bytestring
decodeCTCP :: CTCPByteString -> ByteString
decodeCTCP (CBS bs) | isCTCP bs = unescape . tail . init $ bs
                    | otherwise = bs

    where unescape = pack . catMaybes . snd . mapAccumL step False . unpack

          -- If we fail to find a decoding, ignore the escape.
          step True x = (False, Just . fromMaybe x $ lookup x decodings)

          -- Enter escape mode, this doesn't add a character to the
          -- output.
          step False 0o020 = (True, Nothing)

          step _ x = (False, Just x)

soh :: Integral i => i
soh = 0o001

esc :: Integral i => i
esc = 0o020

encodings :: Integral i => [(i, i)]
encodings = [ (0o000, 0o060)
            , (0o012, 0o156)
            , (0o015, 0o162)
            , (0o020, 0o020)
            ]

decodings :: Integral i => [(i, i)]
decodings = map swap encodings

-- *Utilities

-- |Check if a message body represents a CTCP. CTCPs are at least two
-- bytes long, and start and end with a SOH.
isCTCP :: ByteString -> Bool
isCTCP bs = and $ (length bs >= 2) : (head bs == soh) : (last bs == soh) : map (flip notElem bs . fst) encodings

-- |Apply one of two functions depending on whether the bytestring is
-- a CTCP or not.
orCTCP :: (ByteString -> a) -> (CTCPByteString -> a) -> ByteString -> a
orCTCP f g bs | isCTCP bs = g $ CBS bs
              | otherwise = f bs