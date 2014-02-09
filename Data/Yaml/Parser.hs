{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
module Data.Yaml.Parser where

import Text.Libyaml
import Control.Applicative ((<$>), Applicative (..), Alternative (..))
import Data.Monoid (Monoid (..))
import Control.Monad (MonadPlus (..), liftM, ap)
import Control.Monad.Trans.Writer.Strict (tell, WriterT)
import Control.Monad.Trans.Class (lift)
import qualified Data.Map as Map
import Data.Conduit
import Data.Conduit.Lift (runWriterSC)
import Data.Text (Text, pack, unpack)
import Data.Text.Encoding (decodeUtf8)
import Data.ByteString (ByteString)
import Control.Exception (Exception)
import Data.Typeable (Typeable)
import Data.Text.Read (signed, decimal)

newtype YamlParser a = YamlParser
    { unYamlParser :: AnchorMap -> Either Text a
    }
instance Functor YamlParser where
    fmap = liftM
instance Applicative YamlParser where
    pure = return
    (<*>) = ap
instance Alternative YamlParser where
    empty = fail "empty"
    (<|>) = mplus
instance Monoid (YamlParser a) where
    mempty = fail "mempty"
    mappend = mplus
instance Monad YamlParser where
    return = YamlParser . const . Right
    YamlParser f >>= g = YamlParser $ \am ->
        case f am of
            Left t -> Left t
            Right x -> unYamlParser (g x) am
    fail = YamlParser . const . Left . pack
instance MonadPlus YamlParser where
    mzero = fail "mzero"
    mplus a b = YamlParser $ \am ->
        case unYamlParser a am of
            Left _ -> unYamlParser b am
            x -> x

lookupAnchor :: AnchorName -> YamlParser (Maybe YamlValue)
lookupAnchor name = YamlParser $ Right . Map.lookup name

withAnchor :: AnchorName -> Text -> (YamlValue -> YamlParser a) -> YamlParser a
withAnchor name expected f = do
    mv <- lookupAnchor name
    case mv of
        Nothing -> fail $ unpack expected ++ ": unknown alias " ++ name
        Just v -> f v

withMapping :: Text -> ([(Text, YamlValue)] -> YamlParser a) -> YamlValue -> YamlParser a
withMapping _ f (Mapping m _) = f m
withMapping expected f (Alias an) = withAnchor an expected $ withMapping expected f
withMapping expected _ v = typeMismatch expected v

withSequence :: Text -> ([YamlValue] -> YamlParser a) -> YamlValue -> YamlParser a
withSequence _ f (Sequence s _) = f s
withSequence expected f (Alias an) = withAnchor an expected $ withSequence expected f
withSequence expected _ v = typeMismatch expected v

withText :: Text -> (Text -> YamlParser a) -> YamlValue -> YamlParser a
withText _ f (Scalar s _ _ _) = f $ decodeUtf8 s
withText expected f (Alias an) = withAnchor an expected $ withText expected f
withText expected _ v = typeMismatch expected v

typeMismatch :: Text -> YamlValue -> YamlParser a
typeMismatch expected v =
    fail $ concat
        [ "Expected "
        , unpack expected
        , ", but got: "
        , t
        ]
  where
    t = case v of
        Mapping _ _ -> "mapping"
        Sequence _ _ -> "sequence"
        Scalar _ _ _ _ -> "scalar"
        Alias _ -> "alias"

class FromYaml a where
    fromYaml :: YamlValue -> YamlParser a
instance FromYaml YamlValue where
    fromYaml = return
instance FromYaml a => FromYaml [a] where
    fromYaml = withSequence "[a]" (mapM fromYaml)
instance FromYaml Text where
    fromYaml = withText "Text" return
instance FromYaml Int where
    fromYaml =
        withText "Int" go
      where
        go t =
            case signed decimal t of
                Right (i, "") -> return i
                _ -> fail $ "Invalid Int: " ++ unpack t

data YamlValue
    = Mapping [(Text, YamlValue)] Anchor
    | Sequence [YamlValue] Anchor
    | Scalar ByteString Tag Style Anchor
    | Alias AnchorName
    deriving Show

type AnchorMap = Map.Map AnchorName YamlValue
data RawDoc = RawDoc YamlValue AnchorMap
    deriving Show

parseRawDoc :: (FromYaml a, MonadThrow m) => RawDoc -> m a
parseRawDoc (RawDoc val am) =
    case unYamlParser (fromYaml val) am of
        Left t -> monadThrow $ FromYamlException t
        Right x -> return x

(.:) :: FromYaml a => [(Text, YamlValue)] -> Text -> YamlParser a
o .: k =
    case lookup k o of
        Nothing -> fail $ "Key not found: " ++ unpack k
        Just v -> fromYaml v

data YamlParseException
    = UnexpectedEndOfEvents
    | UnexpectedEvent Event
    | FromYamlException Text
    deriving (Show, Typeable)
instance Exception YamlParseException

sinkValue :: MonadThrow m => Consumer Event (WriterT AnchorMap m) YamlValue
sinkValue =
    start
  where
    start = await >>= maybe (monadThrow UnexpectedEndOfEvents) go

    tell' Nothing val = return val
    tell' (Just name) val = do
        lift $ tell $ Map.singleton name val
        return val

    go EventStreamStart = start
    go EventDocumentStart = start
    go (EventAlias a) = return $ Alias a
    go (EventScalar a b c d) = tell' d $ Scalar a b c d
    go (EventSequenceStart mname) = do
        vals <- goS id
        let val = Sequence vals mname
        tell' mname val
    go (EventMappingStart mname) = do
        pairs <- goM id
        let val = Mapping pairs mname
        tell' mname val

    go e = monadThrow $ UnexpectedEvent e

    goS front = do
        me <- await
        case me of
            Nothing -> monadThrow UnexpectedEndOfEvents
            Just EventSequenceEnd -> return $ front []
            Just e -> do
                val <- go e
                goS (front . (val:))

    goM front = do
        mk <- await
        case mk of
            Nothing -> monadThrow UnexpectedEndOfEvents
            Just EventMappingEnd -> return $ front []
            Just (EventScalar a b c d) -> do
                _ <- tell' d $ Scalar a b c d
                let k = decodeUtf8 a
                v <- start
                goM (front . ((k, v):))

sinkRawDoc :: MonadThrow m => Consumer Event m RawDoc
sinkRawDoc = uncurry RawDoc <$> runWriterSC sinkValue

readYamlFile :: FromYaml a => FilePath -> IO a
readYamlFile fp = runResourceT (decodeFile fp $$ sinkRawDoc) >>= parseRawDoc