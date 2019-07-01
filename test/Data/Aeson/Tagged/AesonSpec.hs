{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Aeson.Tagged.AesonSpec (spec) where

import BasePrelude
import Data.Aeson.Tagged
import Data.Text (Text)
import qualified Data.Aeson as A
import Data.Aeson.Types (Result(..))

import Test.Hspec
import Utils
import Types

spec :: Spec
spec = do
    aesonTypeAnnotationSpec
    taggedAesonSpec

-- TODO: Does "deriving via WithAeson" work?
-- TODO: Does "deriving via WithAeson1" work? On stuff that has FromJSON1? On Set and HashSet?

----------------------------------------------------------------------------
-- parseJSON @Aeson and toJSON @Aeson
----------------------------------------------------------------------------

aesonTypeAnnotationSpec :: Spec
aesonTypeAnnotationSpec = describe "@Aeson type annotation" $ do
    it "parseJSON @Aeson" $ do
        parse (parseJSON @Aeson) [value|"a"|]
            `shouldBe` Success ("a" :: Text)

    it "toJSON @Aeson" $ do
        toJSON @Aeson ("a" :: Text)
            `shouldBe` [value|"a"|]

----------------------------------------------------------------------------
-- TaggedAeson and fromTaggedAeson
----------------------------------------------------------------------------

taggedAesonSpec :: Spec
taggedAesonSpec = describe "TaggedAeson" $ do
    it "works with 'decode'" $ do
        fromTaggedAeson @Modded <$> A.decode "\"modded:a\""
            `shouldBe` Just ("a" :: Text)

    it "works with 'encode'" $ do
        A.encode (TaggedAeson @Modded ("a" :: Text))
            `shouldBe` "\"modded:a\""
