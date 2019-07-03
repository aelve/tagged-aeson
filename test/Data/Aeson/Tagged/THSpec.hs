{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Note: all types here must not have Aeson instances.
module Data.Aeson.Tagged.THSpec (spec) where

import BasePrelude
import Data.Aeson.Tagged
import qualified Data.Aeson as A
import qualified Data.Aeson.TH as A
import qualified Data.Aeson.Encoding as A
import qualified Data.Aeson.Types as A

import Test.Hspec
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import HaskellWorks.Hspec.Hedgehog

import Utils
import Types

spec :: Spec
spec = describe "Template Haskell deriving" $ do
    -- Note: we are not testing 'deriveFromJSON' and 'deriveToJSON' because
    -- they are more-or-less tested as part of testing 'deriveJSON'
    thSingleSpec
    thEnumSpec
    thADTSpec
    thRecordSpec
    thADTRecordSpec

-- TODO: use more tests from Aeson itself

-- TODO: records with optional fields
-- TODO: for fields that are lists, we want to make sure they require and use a [] instance

-- TODO: port all tests from https://github.com/bos/aeson/blob/master/tests/Encoders.hs

-- TODO: which instance will be used for lists?
-- TODO: warn that overriding toJSONList and ToJSON [] in different ways will cause trouble

-- TODO: make sure 'parse2ElemArray' is also exercised

-- TODO: make sure the 'conKey' hack doesn't interfere with parsing of
-- record fields named "conKey"

----------------------------------------------------------------------------
-- Tags
----------------------------------------------------------------------------

-- | A tag for TH-derived instances.
data Derived (k :: Flavor)

-- | A tag for correct instances, either written manually or derived with
-- Aeson's help.
data Golden (k :: Flavor)

data Flavor = FDefault | F2ElemArray | FTaggedObject | FObjectWithSingleField

class SFlavor (k :: Flavor) where flavor :: Flavor
instance SFlavor 'FDefault where flavor = FDefault
instance SFlavor 'F2ElemArray where flavor = F2ElemArray
instance SFlavor 'FTaggedObject where flavor = FTaggedObject
instance SFlavor 'FObjectWithSingleField where flavor = FObjectWithSingleField

----------------------------------------------------------------------------
-- Hedgehog properties
----------------------------------------------------------------------------

-- | Test that JSON generated by a golden instance can be parsed back by a
-- derived instance.
prop_parseJSON
    :: forall k a
     . (FromJSON (Derived k) a, ToJSON (Golden k) a, Show a, Eq a)
    => Gen a -> Property
prop_parseJSON gen = property $ do
    a <- forAll gen
    let val = using @(Golden k) (toJSON a)
    parseEither (parseJSON @(Derived k)) val === Right a

-- | Test that JSON generated by a golden instance can be parsed back by a
-- derived instance via 'parseJSONList'.
prop_parseJSONList
    :: forall k a
     . (FromJSON (Derived k) a, ToJSON (Golden k) a, Show a, Eq a)
    => Gen [a] -> Property
prop_parseJSONList gen = property $ do
    a <- forAll gen
    let val = using @(Golden k) (toJSONList a)
    parseEither (parseJSONList @(Derived k)) val === Right a

-- | Test that JSON generated by a derived instance can be parsed back by a
-- golden instance.
prop_toJSON
    :: forall k a
     . (ToJSON (Derived k) a, FromJSON (Golden k) a, Show a, Eq a)
    => Gen a -> Property
prop_toJSON gen = property $ do
    a <- forAll gen
    let val = using @(Derived k) (toJSON a)
    parseEither (parseJSON @(Golden k)) val === Right a

-- | Test that a JSON list generated by a derived instance can be parsed
-- back by a golden instance.
prop_toJSONList
    :: forall k a
     . (ToJSON (Derived k) a, FromJSON (Golden k) a, Show a, Eq a)
    => Gen [a] -> Property
prop_toJSONList gen = property $ do
    a <- forAll gen
    let val = using @(Derived k) (toJSONList a)
    parseEither (parseJSONList @(Golden k)) val === Right a

-- | Test that 'Encoding' generated by a derived instance can be parsed back
-- by a golden instance.
prop_toEncoding
    :: forall k a
     . (ToJSON (Derived k) a, FromJSON (Golden k) a, Show a, Eq a)
    => Gen a -> Property
prop_toEncoding gen = property $ do
    a <- forAll gen
    let bs = coerce A.encodingToLazyByteString (using @(Derived k) (toEncoding a))
        val = Value <$> A.eitherDecode bs
    (parseEither (parseJSON @(Golden k)) =<< val) === Right a

-- | Test that an 'Encoding' list generated by a derived instance can be
-- parsed back by a golden instance.
prop_toEncodingList
    :: forall k a
     . (ToJSON (Derived k) a, FromJSON (Golden k) a, Show a, Eq a)
    => Gen [a] -> Property
prop_toEncodingList gen = property $ do
    a <- forAll gen
    let bs = coerce A.encodingToLazyByteString (using @(Derived k) (toEncodingList a))
        val = Value <$> A.eitherDecode bs
    (parseEither (parseJSONList @(Golden k)) =<< val) === Right a

-- | A combination of all tests.
hedgehogSpec
    :: forall k a
     . (FromJSON (Derived k) a, ToJSON (Derived k) a,
        FromJSON (Golden k) a, ToJSON (Golden k) a,
        Eq a, Show a)
    => Gen a -> Spec
hedgehogSpec gen = do
    it "derived parseJSON works" $ do
        require $ prop_parseJSON @k gen
    it "derived parseJSONList works" $ do
        require $ prop_parseJSONList @k (Gen.list (Range.linear 0 10) gen)
    it "derived toJSON works" $ do
        require $ prop_toJSON @k gen
    it "derived toJSONList works" $ do
        require $ prop_toJSONList @k (Gen.list (Range.linear 0 10) gen)
    it "derived toEncoding works" $ do
        require $ prop_toEncoding @k gen
    it "derived toEncodingList works" $ do
        require $ prop_toEncodingList @k (Gen.list (Range.linear 0 10) gen)

----------------------------------------------------------------------------
-- Wrapping one field
----------------------------------------------------------------------------

data THSingle a = THSingle a
    deriving stock (Eq, Show)

genTHSingle :: Gen (THSingle Int')
genTHSingle = THSingle <$> genInt'

thSingleSpec :: Spec
thSingleSpec = describe "THSingle (wrapping one field)" $ do
    describe "defaultOptions" $
        hedgehogSpec @'FDefault genTHSingle
    describe "opts2ElemArray" $
        hedgehogSpec @'F2ElemArray genTHSingle
    describe "optsTaggedObject" $
        hedgehogSpec @'FTaggedObject genTHSingle
    describe "optsObjectWithSingleField" $
        hedgehogSpec @'FObjectWithSingleField genTHSingle

----------------------------------------------------------------------------
-- Enum
----------------------------------------------------------------------------

data THEnum = THEnum1 | THEnum2
    deriving stock (Eq, Show)

genTHEnum :: Gen THEnum
genTHEnum = Gen.element [THEnum1, THEnum2]

thEnumSpec :: Spec
thEnumSpec = describe "THEnum (enum datatype)" $ do
    describe "defaultOptions" $
        hedgehogSpec @'FDefault genTHEnum
    describe "opts2ElemArray" $
        hedgehogSpec @'F2ElemArray genTHEnum
    describe "optsTaggedObject" $
        hedgehogSpec @'FTaggedObject genTHEnum
    describe "optsObjectWithSingleField" $
        hedgehogSpec @'FObjectWithSingleField genTHEnum

----------------------------------------------------------------------------
-- ADT
----------------------------------------------------------------------------

data THADT a = THADT1 | THADT2 a a
    deriving stock (Eq, Show)

genTHADT :: Gen (THADT Int')
genTHADT = Gen.choice [pure THADT1, THADT2 <$> genInt' <*> genInt']

thADTSpec :: Spec
thADTSpec = describe "THADT (ADT datatype)" $ do
    describe "defaultOptions" $
        hedgehogSpec @'FDefault genTHADT
    describe "opts2ElemArray" $
        hedgehogSpec @'F2ElemArray genTHADT
    describe "optsTaggedObject" $
        hedgehogSpec @'FTaggedObject genTHADT
    describe "optsObjectWithSingleField" $
        hedgehogSpec @'FObjectWithSingleField genTHADT

----------------------------------------------------------------------------
-- Record
----------------------------------------------------------------------------

data THRecord a = THRecord {rec1 :: a, rec2 :: a}
    deriving stock (Eq, Show)

genTHRecord :: Gen (THRecord Int')
genTHRecord = THRecord <$> genInt' <*> genInt'

thRecordSpec :: Spec
thRecordSpec = describe "THRecord (record)" $ do
    describe "defaultOptions" $
        hedgehogSpec @'FDefault genTHRecord
    describe "opts2ElemArray" $
        hedgehogSpec @'F2ElemArray genTHRecord
    describe "optsTaggedObject" $
        hedgehogSpec @'FTaggedObject genTHRecord
    describe "optsObjectWithSingleField" $
        hedgehogSpec @'FObjectWithSingleField genTHRecord

----------------------------------------------------------------------------
-- ADT with a record branch
----------------------------------------------------------------------------

data THADTRecord a = THADTRecord1 a | THADTRecord2 {rec'1, rec'2 :: a}
    deriving stock (Eq, Show)

genTHADTRecord :: Gen (THADTRecord Int')
genTHADTRecord = Gen.choice
    [ THADTRecord1 <$> genInt'
    , THADTRecord2 <$> genInt' <*> genInt'
    ]

thADTRecordSpec :: Spec
thADTRecordSpec = describe "THADTRecord (ADT with a record branch)" $ do
    describe "defaultOptions" $
        hedgehogSpec @'FDefault genTHADTRecord
    describe "opts2ElemArray" $
        hedgehogSpec @'F2ElemArray genTHADTRecord
    describe "optsTaggedObject" $
        hedgehogSpec @'FTaggedObject genTHADTRecord
    describe "optsObjectWithSingleField" $
        hedgehogSpec @'FObjectWithSingleField genTHADTRecord

----------------------------------------------------------------------------
-- Options
----------------------------------------------------------------------------

-- TODO reexport 'Options' and some other things from tagged-aeson

-- TODO tests in Aeson also use:
--   optsUntaggedValue
--   optsUnwrapUnaryRecords
--   optsTagSingleConstructors

----------------------------------------------------------------------------
-- THSingle instances
----------------------------------------------------------------------------

deriveJSON [t|Derived 'FDefault|] A.defaultOptions ''THSingle
deriveJSON [t|Derived 'F2ElemArray|] opts2ElemArray ''THSingle
deriveJSON [t|Derived 'FTaggedObject|] optsTaggedObject ''THSingle
deriveJSON [t|Derived 'FObjectWithSingleField|] optsObjectWithSingleField ''THSingle

instance SFlavor k => FromJSON (Golden k) (THSingle Int') where
    parseJSON = coerce @(A.Value -> A.Parser (THSingle Int)) $
        case flavor @k of
            FDefault -> $(A.mkParseJSON A.defaultOptions ''THSingle)
            F2ElemArray -> $(A.mkParseJSON opts2ElemArray ''THSingle)
            FTaggedObject -> $(A.mkParseJSON optsTaggedObject ''THSingle)
            FObjectWithSingleField -> $(A.mkParseJSON optsObjectWithSingleField ''THSingle)

instance SFlavor k => ToJSON (Golden k) (THSingle Int') where
    toJSON = coerce @(THSingle Int -> A.Value) $
        case flavor @k of
            FDefault -> $(A.mkToJSON A.defaultOptions ''THSingle)
            F2ElemArray -> $(A.mkToJSON opts2ElemArray ''THSingle)
            FTaggedObject -> $(A.mkToJSON optsTaggedObject ''THSingle)
            FObjectWithSingleField -> $(A.mkToJSON optsObjectWithSingleField ''THSingle)
    toEncoding = coerce @(THSingle Int -> A.Encoding) $
        case flavor @k of
            FDefault -> $(A.mkToEncoding A.defaultOptions ''THSingle)
            F2ElemArray -> $(A.mkToEncoding opts2ElemArray ''THSingle)
            FTaggedObject -> $(A.mkToEncoding optsTaggedObject ''THSingle)
            FObjectWithSingleField -> $(A.mkToEncoding optsObjectWithSingleField ''THSingle)

----------------------------------------------------------------------------
-- THEnum instances
----------------------------------------------------------------------------

deriveJSON [t|Derived 'FDefault|] A.defaultOptions ''THEnum
deriveJSON [t|Derived 'F2ElemArray|] opts2ElemArray ''THEnum
deriveJSON [t|Derived 'FTaggedObject|] optsTaggedObject ''THEnum
deriveJSON [t|Derived 'FObjectWithSingleField|] optsObjectWithSingleField ''THEnum

instance SFlavor k => FromJSON (Golden k) THEnum where
    parseJSON = coerce @(A.Value -> A.Parser THEnum) $
        case flavor @k of
            FDefault -> $(A.mkParseJSON A.defaultOptions ''THEnum)
            F2ElemArray -> $(A.mkParseJSON opts2ElemArray ''THEnum)
            FTaggedObject -> $(A.mkParseJSON optsTaggedObject ''THEnum)
            FObjectWithSingleField -> $(A.mkParseJSON optsObjectWithSingleField ''THEnum)

instance SFlavor k => ToJSON (Golden k) THEnum where
    toJSON = coerce @(THEnum -> A.Value) $
        case flavor @k of
            FDefault -> $(A.mkToJSON A.defaultOptions ''THEnum)
            F2ElemArray -> $(A.mkToJSON opts2ElemArray ''THEnum)
            FTaggedObject -> $(A.mkToJSON optsTaggedObject ''THEnum)
            FObjectWithSingleField -> $(A.mkToJSON optsObjectWithSingleField ''THEnum)
    toEncoding = coerce @(THEnum -> A.Encoding) $
        case flavor @k of
            FDefault -> $(A.mkToEncoding A.defaultOptions ''THEnum)
            F2ElemArray -> $(A.mkToEncoding opts2ElemArray ''THEnum)
            FTaggedObject -> $(A.mkToEncoding optsTaggedObject ''THEnum)
            FObjectWithSingleField -> $(A.mkToEncoding optsObjectWithSingleField ''THEnum)

----------------------------------------------------------------------------
-- THADT instances
----------------------------------------------------------------------------

deriveJSON [t|Derived 'FDefault|] A.defaultOptions ''THADT
deriveJSON [t|Derived 'F2ElemArray|] opts2ElemArray ''THADT
deriveJSON [t|Derived 'FTaggedObject|] optsTaggedObject ''THADT
deriveJSON [t|Derived 'FObjectWithSingleField|] optsObjectWithSingleField ''THADT

instance SFlavor k => FromJSON (Golden k) (THADT Int') where
    parseJSON = coerce @(A.Value -> A.Parser (THADT Int)) $
        case flavor @k of
            FDefault -> $(A.mkParseJSON A.defaultOptions ''THADT)
            F2ElemArray -> $(A.mkParseJSON opts2ElemArray ''THADT)
            FTaggedObject -> $(A.mkParseJSON optsTaggedObject ''THADT)
            FObjectWithSingleField -> $(A.mkParseJSON optsObjectWithSingleField ''THADT)

instance SFlavor k => ToJSON (Golden k) (THADT Int') where
    toJSON = coerce @(THADT Int -> A.Value) $
        case flavor @k of
            FDefault -> $(A.mkToJSON A.defaultOptions ''THADT)
            F2ElemArray -> $(A.mkToJSON opts2ElemArray ''THADT)
            FTaggedObject -> $(A.mkToJSON optsTaggedObject ''THADT)
            FObjectWithSingleField -> $(A.mkToJSON optsObjectWithSingleField ''THADT)
    toEncoding = coerce @(THADT Int -> A.Encoding) $
        case flavor @k of
            FDefault -> $(A.mkToEncoding A.defaultOptions ''THADT)
            F2ElemArray -> $(A.mkToEncoding opts2ElemArray ''THADT)
            FTaggedObject -> $(A.mkToEncoding optsTaggedObject ''THADT)
            FObjectWithSingleField -> $(A.mkToEncoding optsObjectWithSingleField ''THADT)

----------------------------------------------------------------------------
-- THRecord instances
----------------------------------------------------------------------------

deriveJSON [t|Derived 'FDefault|] A.defaultOptions ''THRecord
deriveJSON [t|Derived 'F2ElemArray|] opts2ElemArray ''THRecord
deriveJSON [t|Derived 'FTaggedObject|] optsTaggedObject ''THRecord
deriveJSON [t|Derived 'FObjectWithSingleField|] optsObjectWithSingleField ''THRecord

instance SFlavor k => FromJSON (Golden k) (THRecord Int') where
    parseJSON = coerce @(A.Value -> A.Parser (THRecord Int)) $
        case flavor @k of
            FDefault -> $(A.mkParseJSON A.defaultOptions ''THRecord)
            F2ElemArray -> $(A.mkParseJSON opts2ElemArray ''THRecord)
            FTaggedObject -> $(A.mkParseJSON optsTaggedObject ''THRecord)
            FObjectWithSingleField -> $(A.mkParseJSON optsObjectWithSingleField ''THRecord)

instance SFlavor k => ToJSON (Golden k) (THRecord Int') where
    toJSON = coerce @(THRecord Int -> A.Value) $
        case flavor @k of
            FDefault -> $(A.mkToJSON A.defaultOptions ''THRecord)
            F2ElemArray -> $(A.mkToJSON opts2ElemArray ''THRecord)
            FTaggedObject -> $(A.mkToJSON optsTaggedObject ''THRecord)
            FObjectWithSingleField -> $(A.mkToJSON optsObjectWithSingleField ''THRecord)
    toEncoding = coerce @(THRecord Int -> A.Encoding) $
        case flavor @k of
            FDefault -> $(A.mkToEncoding A.defaultOptions ''THRecord)
            F2ElemArray -> $(A.mkToEncoding opts2ElemArray ''THRecord)
            FTaggedObject -> $(A.mkToEncoding optsTaggedObject ''THRecord)
            FObjectWithSingleField -> $(A.mkToEncoding optsObjectWithSingleField ''THRecord)

----------------------------------------------------------------------------
-- THADTRecord instances
----------------------------------------------------------------------------

deriveJSON [t|Derived 'FDefault|] A.defaultOptions ''THADTRecord
deriveJSON [t|Derived 'F2ElemArray|] opts2ElemArray ''THADTRecord
deriveJSON [t|Derived 'FTaggedObject|] optsTaggedObject ''THADTRecord
deriveJSON [t|Derived 'FObjectWithSingleField|] optsObjectWithSingleField ''THADTRecord

instance SFlavor k => FromJSON (Golden k) (THADTRecord Int') where
    parseJSON = coerce @(A.Value -> A.Parser (THADTRecord Int)) $
        case flavor @k of
            FDefault -> $(A.mkParseJSON A.defaultOptions ''THADTRecord)
            F2ElemArray -> $(A.mkParseJSON opts2ElemArray ''THADTRecord)
            FTaggedObject -> $(A.mkParseJSON optsTaggedObject ''THADTRecord)
            FObjectWithSingleField -> $(A.mkParseJSON optsObjectWithSingleField ''THADTRecord)

instance SFlavor k => ToJSON (Golden k) (THADTRecord Int') where
    toJSON = coerce @(THADTRecord Int -> A.Value) $
        case flavor @k of
            FDefault -> $(A.mkToJSON A.defaultOptions ''THADTRecord)
            F2ElemArray -> $(A.mkToJSON opts2ElemArray ''THADTRecord)
            FTaggedObject -> $(A.mkToJSON optsTaggedObject ''THADTRecord)
            FObjectWithSingleField -> $(A.mkToJSON optsObjectWithSingleField ''THADTRecord)
    toEncoding = coerce @(THADTRecord Int -> A.Encoding) $
        case flavor @k of
            FDefault -> $(A.mkToEncoding A.defaultOptions ''THADTRecord)
            F2ElemArray -> $(A.mkToEncoding opts2ElemArray ''THADTRecord)
            FTaggedObject -> $(A.mkToEncoding optsTaggedObject ''THADTRecord)
            FObjectWithSingleField -> $(A.mkToEncoding optsObjectWithSingleField ''THADTRecord)
