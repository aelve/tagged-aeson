{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Aeson.Tagged
(
    -- * Classes
    -- $classes
    FromJSON(..),
    ToJSON(..),

    -- * Interop between aeson and tagged-aeson
    Aeson,
    TaggedAeson(..), fromTaggedAeson,

    -- * Defining instances
    -- $generic
    deriveJSON,
    deriveToJSON,
    deriveFromJSON,
    -- ** Internals
    aesonToTaggedAesonTH,

    -- * Using
    Using(..),

    -- * Parsing combinators
    (.:), (.:?), (.:!),
    withObject, withText, withArray, withScientific, withBool,

    -- * Encoding combinators
    KeyValue(..),
    object,

    -- * Lifting instances from Aeson
    WithAeson(..),
    WithAeson1(..),

    -- * Instance-less
    -- ** Lists
    parseList, parseListWith,
    listToJSON, listToJSONWith,
    listToEncoding, listToEncodingWith,
    -- ** 'NE.NonEmpty'
    parseNonEmpty, parseNonEmptyWith,
    nonEmptyToJSON, nonEmptyToJSONWith,
    nonEmptyToEncoding, nonEmptyToEncodingWith,
    -- ** 'V.Vector'
    parseVector, parseVectorWith,
    vectorToJSON, vectorToJSONWith,
    vectorToEncoding, vectorToEncodingWith,
    -- ** 'S.Set'
    parseSet, parseSetWith,
    setToJSON, setToJSONWith,
    setToEncoding, setToEncodingWith,
    -- ** 'HS.HashSet'
    parseHashSet, parseHashSetWith,
    hashSetToJSON, hashSetToJSONWith,
    hashSetToEncoding, hashSetToEncodingWith,

    -- * Internals
    Parser(..),
    Value(..),
    Encoding(..),
    Series(..),
    Object,
    Array,
    Pair,
)
where

import BasePrelude
import Data.Text (Text)
import Data.Generics.Uniplate.Data (Biplate, transformBi)
import Language.Haskell.TH
import Data.Scientific (Scientific)
import qualified Data.List.NonEmpty as NE
import qualified Data.Vector as V
import qualified Data.HashMap.Strict as HM
import qualified Data.Set as S
import qualified Data.HashSet as HS
import Control.DeepSeq (NFData)
import Data.Hashable (Hashable)

import qualified Data.Aeson          as A
import qualified Data.Aeson.Types    as A
import qualified Data.Aeson.TH       as A
import qualified Data.Aeson.Internal as A
import qualified Data.Aeson.Encoding as E

----------------------------------------------------------------------------
-- Classes
----------------------------------------------------------------------------

-- $classes
--
-- This are tagged analogs of 'A.FromJSON' and 'A.ToJSON' from Aeson. You
-- can write your own instances of these classes, or you can use
-- 'deriveJSON' to autoderive them. Note that generic instances don't work.

-- | tagged-aeson does not provide any 'FromJSON' instances. You have
-- several options for writing them:
--
-- __Lift instances from Aeson:__
--
-- @
-- 'using' \@'Aeson' (o '.:' "name")
-- @
--
-- @
-- instance FromJSON Tag Text where
--     'parseJSON' = 'using' \@'Aeson' 'parseJSON'
-- @
--
-- Note that you should not do this with container types (e.g. lists),
-- because then inner elements would also be parsed according to the Aeson
-- instance and not your tagged-aeson instance.
--
-- __Use a decoding helper:__
--
-- @
-- accounts \<- 'parseList' =\<\< (o '.:' "accounts")
-- @
--
-- @
-- instance FromJSON Tag a => FromJSON Tag [a] where
--     'parseJSON' = 'parseList'
-- @
class FromJSON (tag :: k) a where
    parseJSON :: Value any -> Parser tag a

    parseJSONList :: Value any -> Parser tag [a]
    parseJSONList = parseList

class ToJSON (tag :: k) a where
    toJSON :: a -> Value tag

    toEncoding :: a -> Encoding tag
    toEncoding = coerce E.value . toJSON @tag
    {-# INLINE toEncoding #-}

    toJSONList :: [a] -> Value tag
    toJSONList = listToJSON
    {-# INLINE toJSONList #-}

    toEncodingList :: [a] -> Encoding tag
    toEncodingList = listToEncoding
    {-# INLINE toEncodingList #-}

----------------------------------------------------------------------------
-- Interop between Aeson and tagged-aeson
----------------------------------------------------------------------------

-- | The tag for original Aeson instances. You can use @'parseJSON'
-- \@'Aeson'@ and @'toJSON' \@'Aeson'@ to get Aeson's parsing behavior.
data Aeson

instance A.FromJSON a => FromJSON Aeson a where
    parseJSON = coerce (A.parseJSON @a)
    parseJSONList = coerce (A.parseJSONList @a)

instance A.ToJSON a => ToJSON Aeson a where
    toJSON = coerce (A.toJSON @a)
    toEncoding = coerce (A.toEncoding @a)
    toJSONList = coerce (A.toJSONList @a)
    toEncodingList = coerce (A.toEncodingList @a)

-- | A newtype wrapper to use tagged-aeson instances with functions from
-- Aeson (or @yaml@).
newtype TaggedAeson (tag :: k) a = TaggedAeson a
    deriving (Eq, Ord, Show)

fromTaggedAeson :: forall tag a. TaggedAeson tag a -> a
fromTaggedAeson = coerce

-- | Turns a tagged-aeson instance into an Aeson instance.
instance FromJSON tag a => A.FromJSON (TaggedAeson tag a) where
    parseJSON = coerce @(Value tag -> Parser tag a) parseJSON

    -- TODO: I'm worried that there's too much jumping between FromJSON and
    -- A.FromJSON instances when parsing e.g. @TaggedAeson tag [Foo]@
    parseJSONList = coerce @(Value tag -> Parser tag [a]) parseJSONList

-- | Turns a tagged-aeson instance into an Aeson instance.
instance ToJSON tag a => A.ToJSON (TaggedAeson tag a) where
    toJSON = coerce @(a -> Value tag) toJSON
    toJSONList = coerce @([a] -> Value tag) toJSONList
    toEncoding = coerce @(a -> Encoding tag) toEncoding
    toEncodingList = coerce @([a] -> Encoding tag) toEncodingList

----------------------------------------------------------------------------
-- Defining instances
----------------------------------------------------------------------------

-- $generic
--
-- We do not support generic instances. Instead of writing
--
-- @
-- instance FromJSON Tag Type
-- instance ToJSON Tag Type
-- @
--
-- you need to use 'deriveJSON':
--
-- @
-- deriveJSON ''Tag defaultOptions ''Type
-- @
--
-- You can also use 'deriveFromJSON' and 'deriveToJSON' to get just one
-- instance or the other.

deriveJSON
    :: Q Type      -- ^ Tag to use for instances
    -> A.Options   -- ^ Encoding options
    -> Name        -- ^ Name of the type for which to generate
                   --    'ToJSON' and 'FromJSON' instances
    -> Q [Dec]
deriveJSON qTag opts name = do
    tag <- qTag
    aesonToTaggedAesonTH tag <$> A.deriveJSON opts name

deriveFromJSON
    :: Q Type      -- ^ Tag to use for the instance
    -> A.Options   -- ^ Encoding options
    -> Name        -- ^ Name of the type for which to generate
                   --    a 'FromJSON' instance
    -> Q [Dec]
deriveFromJSON qTag opts name = do
    tag <- qTag
    aesonToTaggedAesonTH tag <$> A.deriveFromJSON opts name

deriveToJSON
    :: Q Type      -- ^ Tag to use for the instance
    -> A.Options   -- ^ Encoding options
    -> Name        -- ^ Name of the type for which to generate
                   --    a 'ToJSON' instance
    -> Q [Dec]
deriveToJSON qTag opts name = do
    tag <- qTag
    aesonToTaggedAesonTH tag <$> A.deriveToJSON opts name

-- | Rewrite instances generated by Aeson by replacing references to Aeson's
-- classes and methods to @tagged-aeson@'s classes and methods.
aesonToTaggedAesonTH
    :: (Biplate a Type, Biplate a Exp)
    => Type  -- ^ Tag
    -> a
    -> a
aesonToTaggedAesonTH tag = transformBi rewriteExp . transformBi rewriteType
  where
    rewriteType a = case lookup a types of
        Just taggedA -> AppT taggedA tag
        Nothing -> a
    types =
        [ (ConT ''A.ToJSON  , ConT ''ToJSON)
        , (ConT ''A.FromJSON, ConT ''FromJSON) ]

    rewriteExp a = case lookup a exps of
        Just taggedA -> AppTypeE taggedA tag
        Nothing -> a
    exps =
        [ (VarE 'A.toJSON        , VarE 'toJSON)
        , (VarE 'A.toJSONList    , VarE 'toJSONList)
        , (VarE 'A.toEncoding    , VarE 'toEncoding)
        , (VarE 'A.toEncodingList, VarE 'toEncodingList)
        , (VarE 'A.parseJSON     , VarE 'parseJSON)
        , (VarE 'A.parseJSONList , VarE 'parseJSONList) ]

{-
keyValuePairWith
(.=)
parseUntaggedValue
parseTaggedObject
parseValue
consToValue
toPair
sumToValue

If the result has any FromJSON/ToJSON constraints from Aeson, it will not compile

todo: check what the different encoding of 'String' will change (will it change tags? I guess it shouldn't)
-}

----------------------------------------------------------------------------
-- Using
----------------------------------------------------------------------------

class Using tag' tag a' a | a' -> tag', a' tag -> a, a -> tag, a tag' -> a' where
    using :: a' -> a
    default using :: Coercible a' a => a' -> a
    using = coerce
    {-# INLINE using #-}

instance Using tag' tag (Parser tag' a) (Parser tag a)
instance Using tag' tag (Value tag') (Value tag)
instance Using tag' tag (Object tag') (Object tag)
instance Using tag' tag (Encoding tag') (Encoding tag)
instance Using tag' tag (Series tag') (Series tag)
instance Using tag' tag (Pair tag') (Pair tag)

instance Using tag' tag (x -> Parser tag' a) (x -> Parser tag a)
instance Using tag' tag (x -> Value tag') (x -> Value tag)
instance Using tag' tag (x -> Object tag') (x -> Object tag)
instance Using tag' tag (x -> Encoding tag') (x -> Encoding tag)
instance Using tag' tag (x -> Series tag') (x -> Series tag)
instance Using tag' tag (x -> Pair tag') (x -> Pair tag)

----------------------------------------------------------------------------
-- Reimplementations
----------------------------------------------------------------------------

newtype Parser (tag :: k) a = Parser (A.Parser a)
    deriving newtype (Functor, Applicative, Alternative, Monad,
                      MonadFail, MonadPlus, Semigroup, Monoid)

newtype Value (tag :: k) = Value A.Value
    deriving newtype (Eq, Read, Show, IsString, NFData, Hashable)
    -- TODO KeyValue instances
    -- TODO FromJSON, ToJSON instances
    -- TODO Generic, Lift, Data instances
    -- TODO add patterns?

newtype Encoding (tag :: k) = Encoding A.Encoding
    deriving newtype (Eq, Ord, Show)

newtype Series (tag :: k) = Series A.Series
    deriving newtype (Semigroup, Monoid)

type Pair tag = (Text, Value tag)

type Object tag = HM.HashMap Text (Value tag)

type Array tag = V.Vector (Value tag)

----------------------------------------------------------------------------
-- Value instances
----------------------------------------------------------------------------

instance FromJSON tag (Value any) where
    parseJSON = pure . coerce
    {-# INLINE parseJSON #-}

instance ToJSON tag (Value any) where
    toJSON = coerce
    {-# INLINE toJSON #-}
    toEncoding = coerce E.value
    {-# INLINE toEncoding #-}

instance A.FromJSON (Value tag) where
    parseJSON = pure . coerce
    {-# INLINE parseJSON #-}

instance A.ToJSON (Value tag) where
    toJSON = coerce
    {-# INLINE toJSON #-}
    toEncoding = coerce E.value
    {-# INLINE toEncoding #-}

----------------------------------------------------------------------------
-- Combinators
----------------------------------------------------------------------------

-- | Retrieve the value associated with the given key of an 'Object'.
-- The result is 'empty' if the key is not present or the value cannot
-- be converted to the desired type.
--
-- This accessor is appropriate if the key and value /must/ be present
-- in an object for it to be valid.  If the key and value are
-- optional, use '.:?' instead.
(.:) :: forall tag a any. (FromJSON tag a)
     => Object any -> Text -> Parser tag a
(.:) = coerce @(A.Object -> Text -> A.Parser (TaggedAeson tag a)) (A..:)
{-# INLINE (.:) #-}

-- | Retrieve the value associated with the given key of an 'Object'. The
-- result is 'Nothing' if the key is not present or if its value is @null@,
-- or 'empty' if the value cannot be converted to the desired type.
--
-- This accessor is most useful if the key and value can be absent
-- from an object without affecting its validity.  If the key and
-- value are mandatory, use '.:' instead.
(.:?) :: forall tag a any. (FromJSON tag a)
      => Object any -> Text -> Parser tag (Maybe a)
(.:?) = coerce @(A.Object -> Text -> A.Parser (Maybe (TaggedAeson tag a))) (A..:?)
{-# INLINE (.:?) #-}

-- | Retrieve the value associated with the given key of an 'Object'.
-- The result is 'Nothing' if the key is not present or 'empty' if the
-- value cannot be converted to the desired type.
--
-- This differs from '.:?' by attempting to parse @null@ the same as any
-- other JSON value, instead of interpreting it as 'Nothing'.
(.:!) :: forall tag a any. (FromJSON tag a)
      => Object any -> Text -> Parser tag (Maybe a)
(.:!) = coerce @(A.Object -> Text -> A.Parser (Maybe (TaggedAeson tag a))) (A..:!)
{-# INLINE (.:!) #-}

withObject
    :: forall tag a any
     . String
    -> (Object any -> Parser tag a)
    -> Value any
    -> Parser tag a
withObject =
    coerce @(String -> (A.Object -> A.Parser a) -> A.Value -> A.Parser a)
    A.withObject

withText
    :: forall tag a any
     . String
    -> (Text -> Parser tag a)
    -> Value any
    -> Parser tag a
withText =
    coerce @(String -> (Text -> A.Parser a) -> A.Value -> A.Parser a)
    A.withText

withArray
    :: forall tag a any
     . String
    -> (Array any -> Parser tag a)
    -> Value any
    -> Parser tag a
withArray =
    coerce @(String -> (A.Array -> A.Parser a) -> A.Value -> A.Parser a)
    A.withArray

withScientific
    :: forall tag a any
     . String
    -> (Scientific -> Parser tag a)
    -> Value any
    -> Parser tag a
withScientific =
    coerce @(String -> (Scientific -> A.Parser a) -> A.Value -> A.Parser a)
    A.withScientific

withBool
    :: forall tag a any
     . String
    -> (Bool -> Parser tag a)
    -> Value any
    -> Parser tag a
withBool =
    coerce @(String -> (Bool -> A.Parser a) -> A.Value -> A.Parser a)
    A.withBool

----------------------------------------------------------------------------
-- Encoding combinators
----------------------------------------------------------------------------

-- | A key-value pair for encoding a JSON object.
class KeyValue (tag :: k) kv | kv -> tag where
    (.=) :: ToJSON tag v => Text -> v -> kv
    infixr 8 .=

instance KeyValue tag (Series tag) where
    name .= value =
        coerce E.pair
            name
            (toEncoding @tag value)
    {-# INLINE (.=) #-}

instance KeyValue tag (Pair tag) where
    name .= value = (name, toJSON value)
    {-# INLINE (.=) #-}

-- | Constructs a singleton 'HM.HashMap'. For calling functions that
--   demand an 'Object' for constructing objects. To be used in
--   conjunction with 'mconcat'. Prefer to use 'object' where possible.
instance KeyValue tag (Object tag) where
    name .= value = HM.singleton name (toJSON value)
    {-# INLINE (.=) #-}

object :: [Pair tag] -> Value tag
object = coerce A.object

----------------------------------------------------------------------------
-- Lifting instances from Aeson
----------------------------------------------------------------------------

-- |
-- @
-- deriving via WithAeson Foo instance FromJSON Tag Foo
-- @
newtype WithAeson a = WithAeson a

instance A.FromJSON a => FromJSON tag (WithAeson a) where
    parseJSON = coerce (A.parseJSON @a)
    parseJSONList = coerce (A.parseJSONList @a)

instance A.ToJSON a => ToJSON tag (WithAeson a) where
    toJSON = coerce (A.toJSON @a)
    toJSONList = coerce (A.toJSONList @a)
    toEncoding = coerce (A.toEncoding @a)
    toEncodingList = coerce (A.toEncodingList @a)

newtype WithAeson1 f a = WithAeson1 (f a)

instance (FromJSON tag a, A.FromJSON1 f) => FromJSON tag (WithAeson1 f a) where
    parseJSON =
        coerce (A.liftParseJSON @f @a)
            (parseJSON @tag @a)
            (parseJSONList @tag @a)

    parseJSONList =
        coerce (A.liftParseJSONList @f @a)
            (parseJSON @tag @a)
            (parseJSONList @tag @a)

instance (ToJSON tag a, A.ToJSON1 f) => ToJSON tag (WithAeson1 f a) where
    toJSON =
        coerce (A.liftToJSON @f @a)
            (toJSON @tag @a)
            (toJSONList @tag @a)

    toJSONList =
        coerce (A.liftToJSONList @f @a)
            (toJSON @tag @a)
            (toJSONList @tag @a)

    toEncoding =
        coerce (A.liftToEncoding @f @a)
            (toEncoding @tag @a)
            (toEncodingList @tag @a)

    toEncodingList =
        coerce (A.liftToEncodingList @f @a)
            (toEncoding @tag @a)
            (toEncodingList @tag @a)

instance {-# OVERLAPPING #-} (FromJSON tag a, Ord a) =>
         FromJSON tag (WithAeson1 S.Set a) where
    parseJSON = coerce (parseSet @tag)

instance {-# OVERLAPPING #-} (ToJSON tag a, Ord a) =>
         ToJSON tag (WithAeson1 S.Set a) where
    toJSON = coerce (setToJSON @tag)
    toEncoding = coerce (setToEncoding @tag)

instance {-# OVERLAPPING #-} (FromJSON tag a, Eq a, Hashable a) =>
         FromJSON tag (WithAeson1 HS.HashSet a) where
    parseJSON = coerce (parseHashSet @tag)

instance {-# OVERLAPPING #-} (ToJSON tag a, Eq a, Hashable a) =>
         ToJSON tag (WithAeson1 HS.HashSet a) where
    toJSON = coerce (hashSetToJSON @tag)
    toEncoding = coerce (hashSetToEncoding @tag)

-- TODO: PrimArray, Storable.Vector, Primitive.Vector, Unboxed.Vector
-- TODO: do we want to handle Ratio?

----------------------------------------------------------------------------
-- Instance-less
----------------------------------------------------------------------------

-- Lists

parseList :: forall tag a any. FromJSON tag a => Value any -> Parser tag [a]
parseList = parseListWith parseJSON
{-# INLINE parseList #-}

parseListWith :: forall tag a any. (Value any -> Parser tag a) -> Value any -> Parser tag [a]
parseListWith p = withArray "[]" $
    zipWithM (parseIndexedJSON p) [0..] . V.toList
{-# INLINE parseListWith #-}

-- TODO: warn that it doesn't correspond to 'toJSONList'
listToJSON :: forall tag a. ToJSON tag a => [a] -> Value tag
listToJSON = listToJSONWith toJSON
{-# INLINE listToJSON #-}

listToJSONWith :: forall tag a. (a -> Value tag) -> [a] -> Value tag
listToJSONWith = coerce (A.listValue @a)
{-# INLINE listToJSONWith #-}

listToEncoding :: forall tag a. ToJSON tag a => [a] -> Encoding tag
listToEncoding = listToEncodingWith toEncoding
{-# INLINE listToEncoding #-}

listToEncodingWith :: forall tag a. (a -> Encoding tag) -> [a] -> Encoding tag
listToEncodingWith = coerce (A.listEncoding @a)
{-# INLINE listToEncodingWith #-}

-- NonEmpty

parseNonEmpty :: forall tag a any. FromJSON tag a => Value any -> Parser tag (NE.NonEmpty a)
parseNonEmpty = parseNonEmptyWith parseJSON
{-# INLINE parseNonEmpty #-}

parseNonEmptyWith :: forall tag a any. (Value any -> Parser tag a) -> Value any -> Parser tag (NE.NonEmpty a)
parseNonEmptyWith p = withArray "NonEmpty" $
    (>>= ne) . sequence .
    zipWith (parseIndexedJSON p) [0..] . V.toList
  where
    ne []     = fail "parsing NonEmpty failed, unpexpected empty list"
    ne (x:xs) = pure (x :| xs)
{-# INLINE parseNonEmptyWith #-}

nonEmptyToJSON :: forall tag a. ToJSON tag a => NE.NonEmpty a -> Value tag
nonEmptyToJSON = nonEmptyToJSONWith toJSON
{-# INLINE nonEmptyToJSON #-}

nonEmptyToJSONWith :: forall tag a. (a -> Value tag) -> NE.NonEmpty a -> Value tag
nonEmptyToJSONWith f = listToJSONWith f . NE.toList
{-# INLINE nonEmptyToJSONWith #-}

nonEmptyToEncoding :: forall tag a. ToJSON tag a => NE.NonEmpty a -> Encoding tag
nonEmptyToEncoding = nonEmptyToEncodingWith toEncoding
{-# INLINE nonEmptyToEncoding #-}

nonEmptyToEncodingWith :: forall tag a. (a -> Encoding tag) -> NE.NonEmpty a -> Encoding tag
nonEmptyToEncodingWith f = listToEncodingWith f . NE.toList
{-# INLINE nonEmptyToEncodingWith #-}

-- Vector

parseVector :: forall tag a any. FromJSON tag a => Value any -> Parser tag (V.Vector a)
parseVector = parseVectorWith parseJSON
{-# INLINE parseVector #-}

parseVectorWith :: forall tag a any. (Value any -> Parser tag a) -> Value any -> Parser tag (V.Vector a)
parseVectorWith p = withArray "Vector" $
    V.mapM (uncurry $ parseIndexedJSON p) . V.indexed
{-# INLINE parseVectorWith #-}

vectorToJSON :: forall tag a. ToJSON tag a => V.Vector a -> Value tag
vectorToJSON = vectorToJSONWith toJSON
{-# INLINE vectorToJSON #-}

vectorToJSONWith :: forall tag a. (a -> Value tag) -> V.Vector a -> Value tag
vectorToJSONWith f = coerce A.Array . V.map f
{-# INLINE vectorToJSONWith #-}

vectorToEncoding :: forall tag a. ToJSON tag a => V.Vector a -> Encoding tag
vectorToEncoding = vectorToEncodingWith toEncoding
{-# INLINE vectorToEncoding #-}

vectorToEncodingWith :: forall tag a. (a -> Encoding tag) -> V.Vector a -> Encoding tag
vectorToEncodingWith f = listToEncodingWith f . V.toList
{-# INLINE vectorToEncodingWith #-}

-- Set

parseSet :: forall tag a any. (Ord a, FromJSON tag a) => Value any -> Parser tag (S.Set a)
parseSet = parseSetWith parseJSON
{-# INLINE parseSet #-}

parseSetWith :: forall tag a any. Ord a => (Value any -> Parser tag a) -> Value any -> Parser tag (S.Set a)
parseSetWith p = fmap S.fromList . parseListWith p
{-# INLINE parseSetWith #-}

setToJSON :: forall tag a. ToJSON tag a => S.Set a -> Value tag
setToJSON = setToJSONWith toJSON
{-# INLINE setToJSON #-}

setToJSONWith :: forall tag a. (a -> Value tag) -> S.Set a -> Value tag
setToJSONWith f = listToJSONWith f . S.toList
{-# INLINE setToJSONWith #-}

setToEncoding :: forall tag a. ToJSON tag a => S.Set a -> Encoding tag
setToEncoding = setToEncodingWith toEncoding
{-# INLINE setToEncoding #-}

setToEncodingWith :: forall tag a. (a -> Encoding tag) -> S.Set a -> Encoding tag
setToEncodingWith f = listToEncodingWith f . S.toList
{-# INLINE setToEncodingWith #-}

-- HashSet

parseHashSet :: forall tag a any. (Hashable a, Eq a, FromJSON tag a) => Value any -> Parser tag (HS.HashSet a)
parseHashSet = parseHashSetWith parseJSON
{-# INLINE parseHashSet #-}

parseHashSetWith :: forall tag a any. (Hashable a, Eq a) => (Value any -> Parser tag a) -> Value any -> Parser tag (HS.HashSet a)
parseHashSetWith p = fmap HS.fromList . parseListWith p
{-# INLINE parseHashSetWith #-}

hashSetToJSON :: forall tag a. ToJSON tag a => HS.HashSet a -> Value tag
hashSetToJSON = hashSetToJSONWith toJSON
{-# INLINE hashSetToJSON #-}

hashSetToJSONWith :: forall tag a. (a -> Value tag) -> HS.HashSet a -> Value tag
hashSetToJSONWith f = listToJSONWith f . HS.toList
{-# INLINE hashSetToJSONWith #-}

hashSetToEncoding :: forall tag a. ToJSON tag a => HS.HashSet a -> Encoding tag
hashSetToEncoding = hashSetToEncodingWith toEncoding
{-# INLINE hashSetToEncoding #-}

hashSetToEncodingWith :: forall tag a. (a -> Encoding tag) -> HS.HashSet a -> Encoding tag
hashSetToEncodingWith f = listToEncodingWith f . HS.toList
{-# INLINE hashSetToEncodingWith #-}

{- TODO

Bool
Double
Float
Int*
Word*
String
Text
IntSet
Scientific
UTCTime
UUID
Value
Maybe
Tree
tuples
Map
HashMap
Seq

note: "This instance includes a bounds check to prevent maliciously large inputs to fill up the memory of the target system. You can newtype Scientific and provide your own instance using withScientific if you want to allow larger inputs."

be careful: `using @Aeson [Foo]` will use Aeson for Foo as well

TODO: ToJSONKey

TODO: can we do without default Value instances?
-}

----------------------------------------------------------------------------
-- Internal
----------------------------------------------------------------------------

parseIndexedJSON :: (Value any -> Parser tag a) -> Int -> Value any -> Parser tag a
parseIndexedJSON p idx value = p value <?> A.Index idx
{-# INLINE parseIndexedJSON #-}

-- TODO export
(<?>) :: forall tag a. Parser tag a -> A.JSONPathElement -> Parser tag a
(<?>) = coerce @(A.Parser a -> A.JSONPathElement -> A.Parser a) (A.<?>)
