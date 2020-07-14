{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

-- Build without optimizations to prevent out-of-memory situations in Hydra CI
{-# OPTIONS_GHC -O0 #-}

module Dhall.Test.QuickCheck where

import Data.Either (isRight)
import Data.Either.Validation (Validation(..))
import Data.Monoid ((<>))
import Data.Void (Void)
import Dhall (ToDhall(..), FromDhall(..), auto, extract, inject, embed, Vector)
import Dhall.Map (Map)
import Dhall.Core
    ( Binding(..)
    , Chunks(..)
    , Const(..)
    , Directory(..)
    , DhallDouble(..)
    , Expr(..)
    , File(..)
    , FilePrefix(..)
    , Import(..)
    , ImportHashed(..)
    , ImportMode(..)
    , ImportType(..)
    , PreferAnnotation(..)
    , Scheme(..)
    , URL(..)
    , Var(..)
    )

import Data.Functor.Identity (Identity(..))
import Data.Typeable (Typeable, typeRep)
import Data.Proxy (Proxy(..))
import Dhall.Set (Set)
import Dhall.Parser (Header(..), createHeader)
import Dhall.Pretty (CharacterSet(..))
import Dhall.Src (Src(..))
import Dhall.Test.Format (format)
import Dhall.TypeCheck (Typer, TypeError)
import Generic.Random (Weights, W, (%), (:+)(..))
import Test.QuickCheck
    ( Arbitrary(..), Gen, Positive(..), Property, NonNegative(..)
    , genericShrink, suchThat, (===), (==>))
import Test.QuickCheck.Instances ()
import Test.Tasty (TestTree)
import Test.Tasty.QuickCheck (QuickCheckTests(..))
import Text.Megaparsec (SourcePos(..), Pos)

import qualified Control.Spoon
import qualified Data.Foldable as Foldable
import qualified Data.List
import qualified Data.Sequence
import qualified Data.SpecialValues
import qualified Data.HashSet
import qualified Data.Set
import qualified Data.Text as Text
import qualified Data.Map
import qualified Data.HashMap.Strict as HashMap
import qualified Dhall.Binary
import qualified Dhall.Context
import qualified Dhall.Core
import qualified Dhall.Diff
import qualified Dhall.Map
import qualified Dhall.Parser as Parser
import qualified Dhall.Set
import qualified Dhall.TypeCheck
import qualified Generic.Random
import qualified Lens.Family as Lens
import qualified Numeric.Natural as Nat
import qualified Test.QuickCheck
import qualified Test.Tasty
import qualified Test.Tasty.QuickCheck
import qualified Text.Megaparsec       as Megaparsec

instance (Arbitrary a, Ord a) => Arbitrary (Set a) where
  arbitrary = Dhall.Set.fromList <$> arbitrary
  shrink = map Dhall.Set.fromList . shrink . Dhall.Set.toList

lift0 :: a -> Gen a
lift0 = pure

lift1 :: Arbitrary a => (a -> b) -> Gen b
lift1 f = f <$> arbitrary

lift2 :: (Arbitrary a, Arbitrary b) => (a -> b -> c) -> Gen c
lift2 f = f <$> arbitrary <*> arbitrary

lift3 :: (Arbitrary a, Arbitrary b, Arbitrary c) => (a -> b -> c -> d) -> Gen d
lift3 f = f <$> arbitrary <*> arbitrary <*> arbitrary

lift4
    :: (Arbitrary a, Arbitrary b, Arbitrary c, Arbitrary d)
    => (a -> b -> c -> d -> e) -> Gen e
lift4 f = f <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

lift5
    :: ( Arbitrary a
       , Arbitrary b
       , Arbitrary c
       , Arbitrary d
       , Arbitrary e
       )
    => (a -> b -> c -> d -> e -> f) -> Gen f
lift5 f =
      f <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary

lift6
    :: ( Arbitrary a
       , Arbitrary b
       , Arbitrary c
       , Arbitrary d
       , Arbitrary e
       , Arbitrary f
       )
    => (a -> b -> c -> d -> e -> f -> g) -> Gen g
lift6 f =
      f <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary

integer :: (Arbitrary a, Num a) => Gen a
integer =
    Test.QuickCheck.frequency
        [ (7, arbitrary)
        , (1, fmap (\x -> x + (2 ^ (64 :: Int))) arbitrary)
        , (1, fmap (\x -> x - (2 ^ (64 :: Int))) arbitrary)
        ]

instance Arbitrary CharacterSet where
    arbitrary = Test.QuickCheck.elements [ ASCII, Unicode ]

instance Arbitrary Header where
    arbitrary = do
      let commentChar =
              Test.QuickCheck.frequency
                  [ (20, Test.QuickCheck.elements [' ' .. '\DEL'])
                  , ( 1, arbitrary)
                  ]

          commentText = Text.pack <$> Test.QuickCheck.listOf commentChar

          multiline = do
              txt <- commentText
              pure $ "{-" <> txt <> "-}"

          singleline = do
              txt <- commentText `suchThat` (not . Text.isInfixOf "\n")
              endOfLine <- Test.QuickCheck.elements ["\n", "\r\n"]
              pure $ "--" <> txt <> endOfLine

          newlines = Text.concat <$> Test.QuickCheck.listOf (pure "\n")

      comments <- do
          n <- Test.QuickCheck.choose (0, 2)
          Test.QuickCheck.vectorOf n $ Test.QuickCheck.oneof
              [ multiline
              , singleline
              , newlines
              ]

      pure . createHeader $ Text.unlines comments

    shrink (Header txt) = createHeader . Text.pack <$> shrink (Text.unpack txt)

instance (Ord k, Arbitrary k, Arbitrary v) => Arbitrary (Map k v) where
    arbitrary = do
        n   <- Test.QuickCheck.choose (0, 2)
        kvs <- Test.QuickCheck.vectorOf n ((,) <$> arbitrary <*> arbitrary)
        -- Sorting the fields here because serialization needs them in order
        return (Dhall.Map.fromList (Data.List.sortOn fst kvs))

    shrink =
            map Dhall.Map.fromList
        .   shrink
        .   Dhall.Map.toList

instance (Arbitrary s, Arbitrary a) => Arbitrary (Binding s a) where
    arbitrary =
        let adapt = fmap ((,) Nothing)
            f a b   = Binding Nothing "_" Nothing (adapt a) Nothing b
            g a b c = Binding Nothing a   Nothing (adapt b) Nothing c

        in  Test.QuickCheck.oneof [ lift2 f, lift3 g ]

    shrink = genericShrink

instance (Arbitrary s, Arbitrary a) => Arbitrary (Chunks s a) where
    arbitrary = do
        n <- Test.QuickCheck.choose (0, 2)
        Chunks <$> Test.QuickCheck.vectorOf n arbitrary <*> arbitrary

    shrink = genericShrink

instance Arbitrary Const where
    arbitrary = Test.QuickCheck.oneof [ pure Type, pure Kind, pure Sort ]

    shrink = genericShrink

instance Arbitrary DhallDouble where
    arbitrary = fmap DhallDouble (Test.QuickCheck.oneof [ arbitrary, special ])
      where
        special = Test.QuickCheck.elements Data.SpecialValues.specialValues

    shrink = genericShrink

instance Arbitrary Directory where
    arbitrary = lift1 Directory

    shrink = genericShrink

instance (Arbitrary s, Arbitrary a) => Arbitrary (PreferAnnotation s a) where
    arbitrary =
        Test.QuickCheck.oneof
            [ pure PreferFromSource
            , PreferFromWith <$> arbitrary
            , pure PreferFromCompletion
            ]

instance (Arbitrary s, Arbitrary a) => Arbitrary (Expr s a) where
    arbitrary =
        Test.QuickCheck.suchThat
            (Generic.Random.withBaseCase
                (Generic.Random.genericArbitraryRecG customGens weights)
                (Var <$> arbitrary)
                )
            standardizedExpression
      where
        customGens
            :: Gen Integer    -- Generates all Integer fields in Expr
            :+ Gen Text.Text  -- Generates all Text fields in Expr
            :+ ()
        customGens =
               integer
               -- 'Lam's and 'Pi's are encoded differently when the binding is
               -- the special string "_", so we generate some of these strings
               -- to improve test coverage for these code paths.
            :+ Test.QuickCheck.oneof [pure "_", arbitrary]
            :+ ()

        -- These weights determine the frequency of constructors in the generated
        -- Expr.
        -- They will fail to compile if the constructors don't appear in the order
        -- in which they are defined in 'Expr'!
        weights :: Weights (Expr s a)
        weights =
              (7 :: W "Const")
            % (7 :: W "Var")
            % (7 :: W "Lam")
            % (7 :: W "Pi")
            % (7 :: W "App")
            % (7 :: W "Let")
            % (1 :: W "Annot")
            % (1 :: W "Bool")
            % (7 :: W "BoolLit")
            % (1 :: W "BoolAnd")
            % (1 :: W "BoolOr")
            % (1 :: W "BoolEQ")
            % (1 :: W "BoolNE")
            % (1 :: W "BoolIf")
            % (1 :: W "Natural")
            % (7 :: W "NaturalLit")
            % (1 :: W "NaturalFold")
            % (1 :: W "NaturalBuild")
            % (1 :: W "NaturalIsZero")
            % (1 :: W "NaturalEven")
            % (1 :: W "NaturalOdd")
            % (1 :: W "NaturalToInteger")
            % (1 :: W "NaturalShow")
            % (1 :: W "NaturalSubtract")
            % (1 :: W "NaturalPlus")
            % (1 :: W "NaturalTimes")
            % (1 :: W "Integer")
            % (7 :: W "IntegerLit")
            % (1 :: W "IntegerClamp")
            % (1 :: W "IntegerNegate")
            % (1 :: W "IntegerShow")
            % (1 :: W "IntegerToDouble")
            % (1 :: W "Double")
            % (7 :: W "DoubleLit")
            % (1 :: W "DoubleShow")
            % (1 :: W "Text")
            % (1 :: W "TextLit")
            % (1 :: W "TextAppend")
            % (1 :: W "TextShow")
            % (1 :: W "List")
            % (1 :: W "ListLit")
            % (1 :: W "ListAppend")
            % (1 :: W "ListBuild")
            % (1 :: W "ListFold")
            % (1 :: W "ListLength")
            % (1 :: W "ListHead")
            % (1 :: W "ListLast")
            % (1 :: W "ListIndexed")
            % (1 :: W "ListReverse")
            % (1 :: W "Optional")
            % (7 :: W "Some")
            % (1 :: W "None")
            % (1 :: W "Record")
            % (7 :: W "RecordLit")
            % (1 :: W "Union")
            % (7 :: W "Combine")
            % (1 :: W "CombineTypes")
            % (7 :: W "Prefer")
            % (7 :: W "RecordCompletion")
            % (1 :: W "Merge")
            % (1 :: W "ToMap")
            % (7 :: W "Field")
            % (7 :: W "Project")
            % (1 :: W "Assert")
            % (1 :: W "Equivalent")
            % (1 :: W "With")
            % (0 :: W "Note")
            % (7 :: W "ImportAlt")
            % (7 :: W "Embed")
            % ()

    shrink expression = filter standardizedExpression (genericShrink expression)

standardizedExpression :: Expr s a -> Bool
standardizedExpression (ListLit  Nothing  xs) =
    not (Data.Sequence.null xs)
standardizedExpression (ListLit (Just _ ) xs) =
    Data.Sequence.null xs
standardizedExpression (Note _ _) =
    False
standardizedExpression (Combine (Just _) _ _) =
    False
standardizedExpression With{} =
    False
standardizedExpression (Prefer PreferFromCompletion _ _) =
    False
standardizedExpression (Prefer (PreferFromWith _) _ _) =
    False
standardizedExpression _ =
    True

instance Arbitrary File where
    arbitrary = lift2 File

    shrink = genericShrink

instance Arbitrary FilePrefix where
    arbitrary = Test.QuickCheck.oneof [ pure Absolute, pure Here, pure Home ]

    shrink = genericShrink

instance Arbitrary Src where
    arbitrary = lift3 Src

    shrink = genericShrink

instance Arbitrary SourcePos where
    arbitrary = lift3 SourcePos

    shrink = genericShrink

instance Arbitrary Pos where
    arbitrary = lift1 (Megaparsec.mkPos . getPositive)

instance Arbitrary ImportType where
    arbitrary =
        Test.QuickCheck.oneof
            [ lift2 Local
            , lift5 (\a b c d e -> Remote (URL a b c d e))
            , lift1 Env
            , lift0 Missing
            ]

    shrink = genericShrink

instance Arbitrary ImportHashed where
    arbitrary =
        lift1 (ImportHashed Nothing)

    shrink (ImportHashed { importType = oldImportType, .. }) = do
        newImportType <- shrink oldImportType
        let importHashed = ImportHashed { importType = newImportType, .. }
        return importHashed

-- The standard does not yet specify how to encode `as Text`, so don't test it
-- yet
instance Arbitrary ImportMode where
    arbitrary = Test.QuickCheck.elements [ Code, RawText, Location ]

    shrink = genericShrink

instance Arbitrary Import where
    arbitrary = lift2 Import

    shrink = genericShrink

instance Arbitrary Scheme where
    arbitrary = Test.QuickCheck.oneof [ pure HTTP, pure HTTPS ]

    shrink = genericShrink

instance Arbitrary URL where
    arbitrary = lift5 URL

    shrink = genericShrink

instance Arbitrary Var where
    arbitrary =
        Test.QuickCheck.oneof
            [ fmap (V "_") (getNonNegative <$> arbitrary)
            , lift1 (\t -> V t 0)
            , lift1 V <*> (getNonNegative <$> arbitrary)
            ]

    shrink = genericShrink

binaryRoundtrip :: Expr () Import -> Property
binaryRoundtrip expression =
        Dhall.Binary.decodeExpression (Dhall.Binary.encodeExpression denotedExpression)
    === Right denotedExpression
  where
    denotedExpression :: Expr Void Import
    denotedExpression = Dhall.Core.denote expression

everythingWellTypedNormalizes :: Expr () () -> Property
everythingWellTypedNormalizes expression =
        isRight (Dhall.TypeCheck.typeWithA filterOutEmbeds Dhall.Context.empty expression)
    ==> Test.QuickCheck.total (Dhall.Core.normalize expression :: Expr () ())
  where
    filterOutEmbeds :: Typer a
    filterOutEmbeds _ = Const Sort -- This could be any ill-typed expression.

isNormalizedIsConsistentWithNormalize :: Expr () Import -> Property
isNormalizedIsConsistentWithNormalize expression =
    case maybeProp of
        Nothing -> Test.QuickCheck.discard
        Just prop -> prop
  where
      maybeProp = do
          nf <- Control.Spoon.spoon (Dhall.Core.normalize expression)
          isNormalized <- Control.Spoon.spoon (Dhall.Core.isNormalized expression)
          return $ isNormalized === (nf == expression)

normalizeWithMIsConsistentWithNormalize :: Expr () Import -> Property
normalizeWithMIsConsistentWithNormalize expression =
    case Control.Spoon.spoon (nfM, nf) of
        Just (a, b) -> a === b
        Nothing -> Test.QuickCheck.discard
  where nfM = runIdentity (Dhall.Core.normalizeWithM (\_ -> Identity Nothing) expression)
        nf = Dhall.Core.normalize expression :: Expr () Import

isSameAsSelf :: Expr () Import -> Property
isSameAsSelf expression =
  hasNoImportAndTypechecks ==> Dhall.Diff.same (Dhall.Diff.diff denoted denoted)
  where denoted = Dhall.Core.denote expression
        hasNoImportAndTypechecks =
          case traverse (\_ -> Left ()) expression of
            Right importlessExpression -> isRight (Dhall.TypeCheck.typeOf importlessExpression)
            Left _ -> False

inferredTypesAreNormalized :: Expr () Import -> Property
inferredTypesAreNormalized expression =
    Test.Tasty.QuickCheck.counterexample report (all Dhall.Core.isNormalized result)
  where
    report =  "Got: " ++ show result
           ++ "\nExpected: " ++ show (fmap Dhall.Core.normalize result
                                      :: Either (TypeError () Import) (Expr () Import))

    result = Dhall.TypeCheck.typeWithA filterOutEmbeds Dhall.Context.empty expression

    filterOutEmbeds :: Typer a
    filterOutEmbeds _ = Const Sort -- This could be any ill-typed expression.

normalizingAnExpressionDoesntChangeItsInferredType :: Expr () Import -> Property
normalizingAnExpressionDoesntChangeItsInferredType expression =
    case (eT0, eT1) of
        (Right t0, Right t1) -> t0 === t1
        _ -> Test.QuickCheck.discard
  where
    eT0 = typeCheck expression
    eT1 = typeCheck (Dhall.Core.normalize expression)

    typeCheck = Dhall.TypeCheck.typeWithA filterOutEmbeds Dhall.Context.empty

    filterOutEmbeds :: Typer a
    filterOutEmbeds _ = Const Sort -- This could be any ill-typed expression.

noDoubleNotes :: Expr () Import -> Property
noDoubleNotes expression =
    length
        [ ()
        | e <- Foldable.toList parsedExpression
        , Note _ (Note _ _) <- Lens.toListOf Dhall.Core.subExpressions e
        ] === 0
  where
    text = Dhall.Core.pretty expression

    parsedExpression = Parser.exprFromText "" text

embedThenExtractIsIdentity
    :: forall a. (ToDhall a, FromDhall a, Eq a, Typeable a, Arbitrary a, Show a)
    => Proxy a
    -> (String, Property, TestTree -> TestTree)
embedThenExtractIsIdentity p =
    ( "Embedding then extracting is identity for " ++ show (typeRep p)
    , Test.QuickCheck.property (prop :: a -> Bool)
    , adjustQuickCheckTests 1000
    )
  where
    prop a = case extract auto (embed inject a) of
        Success a' -> a == a'
        Failure _  -> False

idempotenceTest :: CharacterSet -> Header -> Expr Src Import -> Property
idempotenceTest characterSet header expr =
    let once = format characterSet (header, expr)
    in case Parser.exprAndHeaderFromText mempty once of
        Right (format characterSet -> twice) -> case Parser.exprAndHeaderFromText mempty twice of
            Right (format characterSet -> thrice) -> twice === thrice
            Left _ -> Test.QuickCheck.discard
        Left _ -> Test.QuickCheck.discard

tests :: TestTree
tests =
    testProperties'
        "QuickCheck"
        [ ( "Binary serialization should round-trip"
          , Test.QuickCheck.property binaryRoundtrip
          , adjustQuickCheckTests 100
          )
        , ( "everything well-typed should normalize"
          , Test.QuickCheck.property everythingWellTypedNormalizes
          , adjustQuickCheckTests 100000
          )
        , ( "isNormalized should be consistent with normalize"
          , Test.QuickCheck.property isNormalizedIsConsistentWithNormalize
          , adjustQuickCheckTests 10000
          )
        , ( "normalizeWithM should be consistent with normalize"
          , Test.QuickCheck.property normalizeWithMIsConsistentWithNormalize
          , adjustQuickCheckTests 10000
          )
        , ( "An expression should have no difference with itself"
          , Test.QuickCheck.property isSameAsSelf
          , adjustQuickCheckTests 10000
          )
        , ( "Inferred types should be normalized"
          , Test.QuickCheck.property inferredTypesAreNormalized
          , adjustQuickCheckTests 10000
          )
        , ( "Normalizing an expression doesn't change its inferred type"
          , Test.QuickCheck.property normalizingAnExpressionDoesntChangeItsInferredType
          , adjustQuickCheckTests 10000
          )
        , ( "Parsing an expression doesn't generated doubly-nested Note constructors"
          , Test.QuickCheck.property noDoubleNotes
          , adjustQuickCheckTests 100
          )
        , embedThenExtractIsIdentity (Proxy :: Proxy (Text.Text))
        , embedThenExtractIsIdentity (Proxy :: Proxy [Nat.Natural])
        , embedThenExtractIsIdentity (Proxy :: Proxy (Bool, Double))
        , embedThenExtractIsIdentity (Proxy :: Proxy (Data.Sequence.Seq ()))
        , embedThenExtractIsIdentity (Proxy :: Proxy (Maybe Integer))
        , embedThenExtractIsIdentity (Proxy :: Proxy (Data.Set.Set Nat.Natural))
        , embedThenExtractIsIdentity (Proxy :: Proxy (Data.HashSet.HashSet Text.Text))
        , embedThenExtractIsIdentity (Proxy :: Proxy (Vector Double))
        , embedThenExtractIsIdentity (Proxy :: Proxy (Data.Map.Map Double Bool))
        , embedThenExtractIsIdentity (Proxy :: Proxy (HashMap.HashMap Double Bool))
        , ( "Formatting should be idempotent"
          , Test.QuickCheck.property idempotenceTest

            -- FIXME: While this test is flaky, we set the number of test cases
            -- to 0 by subtracting the default number of tests (100).
            -- To run the test manually, use e.g.
            --    --quickcheck-tests 1000
          , Test.Tasty.adjustOption (subtract (QuickCheckTests 100))
          )
        ]

adjustQuickCheckMaxRatio :: Int -> TestTree -> TestTree
adjustQuickCheckMaxRatio maxSize =
    Test.Tasty.adjustOption (max $ Test.Tasty.QuickCheck.QuickCheckMaxRatio maxSize)

adjustQuickCheckTests :: Int -> TestTree -> TestTree
adjustQuickCheckTests nTests =
    -- Using adjustOption instead of withMaxSuccess allows us to override the number of tests
    -- with the --quickcheck-tests CLI option.
    Test.Tasty.adjustOption (max $ QuickCheckTests nTests)

testProperties' :: String -> [(String, Property, TestTree -> TestTree)] -> TestTree
testProperties' name = Test.Tasty.testGroup name . map f
  where
    f (n, p, adjust) = adjust (Test.Tasty.QuickCheck.testProperty n p)
