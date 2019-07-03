{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

-- TODO: what about the following plan?
--
-- 1. Make a list of all functions in Aeson.TH and its imports that have FromJSON/ToJSON
-- 2. Grep all |] and 'Name, make a list of comparisons
-- 3. Replace all those functions
-- 4. Use coerce in the end

module Data.Aeson.Tagged.TH
(
    deriveJSON,
    deriveFromJSON,
    deriveToJSON,
)
where

import BasePrelude
import qualified Data.Text as T
import Data.Text (Text)
import Data.Generics.Uniplate.Data (Biplate, transformBi)
import Language.Haskell.TH
import Data.DList (DList)
import qualified Data.HashMap.Strict as HM
import qualified Data.DList as DList
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import qualified Data.Aeson.TH as A
import qualified Data.Aeson.Internal as A
import qualified Data.Aeson.Encoding as E
import qualified Data.Aeson.Encoding.Internal as E

import Data.Aeson.Tagged.Wrapped
import Data.Aeson.Tagged.Classes

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

-- TODO: add mkToJSON and friends

-- | Rewrite instances generated by Aeson by replacing references to Aeson's
-- classes and methods to @tagged-aeson@'s classes and methods.
aesonToTaggedAesonTH
    :: ( Biplate a Pat
       , Biplate a Type
       , Biplate a Exp
       , Biplate a Name
       , Biplate a Stmt
       )
    => Type  -- ^ Tag
    -> a
    -> a
aesonToTaggedAesonTH tag =
    transformBi rewriteName .
    transformBi rewritePat .
    transformBi (rewriteExp tag) .
    transformBi (rewriteType tag) .
    transformBi rewriteInfix .
    transformBi rewriteTagDecoding

-- TODO: grep for all [| |] in Data.Aeson.TH

----------------------------------------------------------------------------
-- Replace classes and types
----------------------------------------------------------------------------

rewriteType :: Type -> Type -> Type
rewriteType tag a = case lookup a types of
    Just taggedA -> AppT taggedA tag
    Nothing -> a
  where
    types =
        [ (ConT ''A.ToJSON   , ConT ''ToJSON)
        , (ConT ''A.FromJSON , ConT ''FromJSON)
        , (ConT ''A.Parser   , ConT ''Parser)
        , (ConT ''A.Value    , ConT ''Value)
        , (ConT ''A.Encoding , ConT ''Encoding)
        , (ConT ''A.Series   , ConT ''Series)
        , (ConT ''A.Object   , ConT ''Object)
        , (ConT ''A.Array    , ConT ''Array)
        , (ConT ''A.Pair     , ConT ''Pair)
        -- unsupported
        , (ConT ''A.ToJSON1   , unsupported "ToJSON1")
        , (ConT ''A.ToJSON2   , unsupported "ToJSON2")
        , (ConT ''A.FromJSON1 , unsupported "FromJSON1")
        , (ConT ''A.FromJSON2 , unsupported "FromJSON2")
        ]
    unsupported name = error ("rewriteType: " ++ name ++ " is not supported yet")

----------------------------------------------------------------------------
-- Replace function applications
----------------------------------------------------------------------------

rewriteExp :: Type -> Exp -> Exp
rewriteExp tag = \case
    VarE name
        | Just taggedName <- lookup name exps ->
              AppTypeE (VarE taggedName) tag
        | Just (_, coerceFun) <- find (eqInternalName name . fst) coercibleFuns ->
              VarE coerceFun `AppE` VarE name
        -- Unexported functions
        | name `eqInternalName` ("Data.Aeson.Types.ToJSON", "fromPairs") ->
              VarE 'internal_fromPairs
        | name `eqInternalName` ("Data.Aeson.Types.ToJSON", "pair") ->
              VarE 'internal_pair
        | name `eqInternalName` ("Data.Aeson.TH", "lookupField") ->
              VarE 'lookupField
    ConE name
        -- TODO try to find tests where more of these would be needed
        | name == 'A.Array -> ConE 'Array
        | name == 'A.String -> ConE 'String
    other -> other
  where
    eqInternalName :: Name -> (String, String) -> Bool
    eqInternalName name (moduleName, baseName) =
        (packageNameOnly <$> namePackage name) == Just "aeson" &&
        nameModule name == Just moduleName &&
        nameBase name == baseName

    exps :: [(Name, Name)]
    exps =
        [ ('A.toJSON         , 'toJSON)
        , ('A.toJSONList     , 'toJSONList)
        , ('A.toEncoding     , 'toEncoding)
        , ('A.toEncodingList , 'toEncodingList)
        , ('A.parseJSON      , 'parseJSON)
        , ('A.parseJSONList  , 'parseJSONList)
        , ('(A..:)           , '(.:))
        , ('E.text           , 'encoding_text)
        , ('E.comma          , 'encoding_comma)
        , ('(E.><)           , 'encoding_append)
        , ('E.emptyObject_   , 'encoding_emptyObject_)
        , ('E.emptyArray_    , 'encoding_emptyArray_)
        , ('E.wrapObject     , 'encoding_wrapObject)
        , ('E.wrapArray      , 'encoding_wrapArray)
        -- unsupported
        , ('A.liftToJSON          , unsupported "liftToJSON")
        , ('A.liftToJSON2         , unsupported "liftToJSON2")
        , ('A.liftToEncoding      , unsupported "liftToEncoding")
        , ('A.liftToEncoding2     , unsupported "liftToEncoding2")
        , ('A.liftParseJSON       , unsupported "liftParseJSON")
        , ('A.liftParseJSON2      , unsupported "liftParseJSON2")
        , ('A.toJSONList          , unsupported "toJSONList")
        , ('A.liftToJSONList      , unsupported "liftToJSONList")
        , ('A.liftToJSONList2     , unsupported "liftToJSONList2")
        , ('A.toEncodingList      , unsupported "toEncodingList")
        , ('A.liftToEncodingList  , unsupported "liftToEncodingList")
        , ('A.liftToEncodingList2 , unsupported "liftToEncodingList2")
        , ('A.parseJSONList       , unsupported "parseJSONList")
        , ('A.liftParseJSONList   , unsupported "liftParseJSONList")
        , ('A.liftParseJSONList2  , unsupported "liftParseJSONList2")
        ]
    unsupported name = error ("rewriteExp: " ++ name ++ " is not supported yet")

    -- TODO: this is brittle. Perhaps TH code should use Aeson's Parser, and
    -- only convert to tagged-aeson at the end? (I'm scared of that
    -- approach, it relies on tests for correctness)
    coercibleFuns :: [((String, String), Name)]
    coercibleFuns =
        [ (("Data.Aeson.TH", "unknownFieldFail"), 'coerceParser3)
        , (("Data.Aeson.TH", "noArrayFail"), 'coerceParser2)
        , (("Data.Aeson.TH", "noObjectFail"), 'coerceParser2)
        , (("Data.Aeson.TH", "firstElemNoStringFail"), 'coerceParser2)
        , (("Data.Aeson.TH", "wrongPairCountFail"), 'coerceParser2)
        , (("Data.Aeson.TH", "noStringFail"), 'coerceParser2)
        , (("Data.Aeson.TH", "noMatchFail"), 'coerceParser2)
        , (("Data.Aeson.TH", "not2ElemArray"), 'coerceParser2)
        , (("Data.Aeson.TH", "conNotFoundFail2ElemArray"), 'coerceParser3)
        , (("Data.Aeson.TH", "conNotFoundFailObjectSingleField"), 'coerceParser3)
        , (("Data.Aeson.TH", "conNotFoundFailTaggedObject"), 'coerceParser3)
        , (("Data.Aeson.TH", "parseTypeMismatch'"), 'coerceParser4)
        , (("Data.Aeson.TH", "valueConName"), 'coerce)
        ]

coerceParser2 :: (a -> b -> A.Parser x) -> (a -> b -> Parser tag x)
coerceParser2 = coerce
{-# INLINE coerceParser2 #-}

coerceParser3 :: (a -> b -> c -> A.Parser x) -> (a -> b -> c -> Parser tag x)
coerceParser3 = coerce
{-# INLINE coerceParser3 #-}

coerceParser4 :: (a -> b -> c -> d -> A.Parser x) -> (a -> b -> c -> d -> Parser tag x)
coerceParser4 = coerce
{-# INLINE coerceParser4 #-}

encoding_text :: Text -> Encoding tag
encoding_text = coerce E.text
{-# INLINE encoding_text #-}

encoding_comma :: Encoding tag
encoding_comma = coerce E.comma
{-# INLINE encoding_comma #-}

encoding_append :: Encoding tag -> Encoding tag -> Encoding tag
encoding_append = coerce (E.><)
{-# INLINE encoding_append #-}

encoding_emptyObject_ :: Encoding tag
encoding_emptyObject_ = coerce E.emptyObject_
{-# INLINE encoding_emptyObject_ #-}

encoding_emptyArray_ :: Encoding tag
encoding_emptyArray_ = coerce E.emptyArray_
{-# INLINE encoding_emptyArray_ #-}

encoding_wrapObject :: Encoding tag -> Encoding tag
encoding_wrapObject = coerce E.wrapObject
{-# INLINE encoding_wrapObject #-}

encoding_wrapArray :: Encoding tag -> Encoding tag
encoding_wrapArray = coerce E.wrapArray
{-# INLINE encoding_wrapArray #-}

----------------------------------------------------------------------------
-- Replace patterns
----------------------------------------------------------------------------

rewritePat :: Pat -> Pat
rewritePat = \case
    ConP name ps
        | name == 'A.Object -> ConP 'Object ps
        | name == 'A.Array -> ConP 'Array ps
        | name == 'A.String -> ConP 'String ps
        | name == 'A.Number -> ConP 'Number ps
        | name == 'A.Bool -> ConP 'Bool ps
        | name == 'A.Null -> ConP 'Null ps
    x -> x

----------------------------------------------------------------------------
-- Replace names
----------------------------------------------------------------------------

-- | Replace names elsewhere (e.g. in left sides in instance method
-- declarations). This step has to be done last because otherwise we would
-- change names in function applications without adding type annotations.
--
-- TODO: or maybe we don't need type annotations anymore.
rewriteName :: Name -> Name
rewriteName a = case lookup a names of
    Just taggedA -> taggedA
    Nothing -> a
  where
    names =
        [ ('A.toJSON        , 'toJSON)
        , ('A.toJSONList    , 'toJSONList)
        , ('A.toEncoding    , 'toEncoding)
        , ('A.toEncodingList, 'toEncodingList)
        , ('A.parseJSON     , 'parseJSON)
        , ('A.parseJSONList , 'parseJSONList)
        ]

    -- TODO: do we have any references to FromJSON1 methods?

-- | Get package name from 'Name''s 'namePackage'.
--
-- >>> map packageNameOnly ["aeson", "aeson-2", "aeson-1.4", "aeson-1.4-abc"]
-- ["aeson", "aeson", "aeson", "aeson"]
--
-- >>> packageNameOnly "aeson-foo1-1"
-- "aeson-foo1"
packageNameOnly :: String -> String
packageNameOnly =
    -- Luckily, "aeson-2" is not a valid package name, but necessarily name+version.
    -- See <https://hackage.haskell.org/package/Cabal/docs/Distribution-Parsec-Class.html#v:parsecUnqualComponentName>
    T.unpack .
    T.intercalate "-" .
    takeWhile (T.any isAlpha) .
    T.splitOn "-" .
    T.pack

{-
todo: check what the different encoding of 'String' will change (will it
change tags? I guess it shouldn't)
-}

-- | Our copy of @FromPairs@. The original is not exported from Aeson.
class Monoid pairs => FromPairs enc pairs | enc -> pairs where
    internal_fromPairs :: pairs -> enc

instance FromPairs (Encoding tag) (Series tag) where
    internal_fromPairs = coerce E.pairs

instance FromPairs (Value tag) (DList (Pair tag)) where
    internal_fromPairs = object . toList

-- | Our copy of @KeyValuePair@. The original is not exported from Aeson.
class Monoid kv => KeyValuePair v kv where
    internal_pair :: String -> v -> kv

instance (v ~ Value tag) => KeyValuePair v (DList (Pair tag)) where
    internal_pair k v = DList.singleton (T.pack k, v)

instance (e ~ Encoding tag) => KeyValuePair e (Series tag) where
    internal_pair = coerce E.pairStr

-- | Our copy of @LookupField@. The original is not exported from Aeson.
--
-- TODO: perhaps we shouldn't have @Maybe a@ support there, or it should be
-- optional and disabled by default. Or perhaps it should rely on the @Maybe@
-- instance if it's present.
class LookupField a where
    lookupField :: (Value any -> Parser tag a) -> String -> String
                -> Object any -> T.Text -> Parser tag a

instance {-# OVERLAPPABLE #-} LookupField a where
    lookupField pj tName rec obj key =
        case HM.lookup key obj of
            Nothing -> unknownFieldFail tName rec (T.unpack key)
            Just v  -> pj v <?> A.Key key

instance {-# INCOHERENT #-} LookupField (Maybe a) where
    lookupField pj _ _ obj key =
        case HM.lookup key obj of
            Nothing -> pure Nothing
            Just v  -> pj v <?> A.Key key

unknownFieldFail :: String -> String -> String -> Parser tag fail
unknownFieldFail tName rec key =
    fail $ printf "When parsing the record %s of type %s the key %s was not present."
                  rec tName key

{- TODO what is this for?

instance {-# INCOHERENT #-} LookupField (Semigroup.Option a) where
    lookupField pj tName rec obj key =
        fmap Semigroup.Option
             (lookupField (fmap Semigroup.getOption . pj) tName rec obj key)
-}

----------------------------------------------------------------------------
-- Other
----------------------------------------------------------------------------

-- | Rewrite InfixE and UInfixE as AppE.
--
-- Rationale: we rewrite @(.:)@ to @(.:) \@tag@, and GHC crashes when InfixE
-- contains a compound expression.
--
-- TODO: this won't be needed if we get rid of tags.
rewriteInfix :: Exp -> Exp
rewriteInfix = \case
    InfixE Nothing b Nothing -> b
    InfixE (Just a) b Nothing -> b `AppE` a
    InfixE Nothing b (Just c) -> VarE 'flip `AppE` b `AppE` c
    InfixE (Just a) b (Just c) -> (b `AppE` a) `AppE` c
    UInfixE a b c -> (b `AppE` a) `AppE` c
    other -> other

-- | Make sure parsing tags does not require a @FromJSON Text@ instance.
--
-- TODO: same for rendering tags.
rewriteTagDecoding :: Stmt -> Stmt
rewriteTagDecoding = \case
    BindS (VarP lhs) (InfixE (Just a) (VarE op) (Just b))
        | nameBase lhs == "conKey"
        , VarE _obj <- a
        , AppE (VarE pack) (LitE (StringL _key)) <- b
        , pack == 'T.pack
        , op == '(A..:) ->
              BindS (VarP lhs) (VarE 'parseText `AppE` a `AppE` b)
    other -> other

parseText :: Object any -> Text -> Parser tag Text
parseText = coerce @(A.Object -> Text -> A.Parser Text) (A..:)
