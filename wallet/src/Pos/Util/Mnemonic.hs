-- | Module providing restoring from backup phrase functionality
{-# LANGUAGE DataKinds      #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies   #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Pos.Util.Mnemonic
       (
       -- * Types
         Mnemonic
       , Entropy
       , WordCount(..)

       -- * Errors
       , MnemonicErr(..)
       , MnemonicException(..)

       -- * Creating @Mnemonic@ (resp. @Entropy@)
       , mkEntropy
       , mkMnemonic
       , genEntropy

       -- * Accessing properties of types
       , entropyLength
       , checksumLength

       -- * Converting from and to @Mnemonic@ (resp. @Entropy@)
       , mnemonicToEntropy
       , mnemonicToSeed
       , mnemonicToAESKey
       , entropyToMnemonic
       , entropyToByteString
       ) where

import           Universum

import           Control.Lens ((?~))
import           Crypto.Hash (Blake2b_256, Digest, SHA256, hash)
import           Data.Aeson (FromJSON (..), ToJSON (..))
import           Data.Aeson.Types (Parser)
import           Data.ByteArray (convert)
import           Data.ByteString (ByteString)
import           Data.Char (isAscii)
import           Data.Default (Default (def))
import           Data.List (elemIndex, (!!))
import           Data.Swagger (NamedSchema (..), ToSchema (..), maxItems, minItems)
import           Formatting (bprint, build, (%))
import           Serokell.Util (listJson)
import           Test.QuickCheck (Arbitrary (..))
import           Test.QuickCheck.Gen (vectorOf)

import           Pos.Binary (serialize')
import           Pos.Crypto (AesKey (..))
import           Pos.Util.Bits (Bit, Word11, fromBits, toBits)
import           Pos.Util.LogSafe (SecureLog)


import qualified Crypto.Random.Entropy as Crypto
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.Text as Text
import qualified Data.Text.Buildable

--
-- TYPES
--

-- | A backup-phrase in the form of a non-empty of Mnemonic words
-- Constructor isn't exposed.
data Mnemonic (w :: WordCount) = Mnemonic
    { mnemonicToEntropy :: Entropy w
    , mnemonicToWords   :: [(Word11, Text)]
    } deriving (Eq, Show, Generic)

-- | Entropy as a non-empty sequence of bytes, multiple of 4 bytes
newtype Entropy (w :: WordCount) = Entropy { entropyToByteString :: ByteString }
    deriving (Eq, Show, Generic)

-- | Number of words that are supported, so far
--
--  - 9 for redemption certificates
--  - 12 for wallets backup phrases
data WordCount = NineWords | TwelveWords


--
-- ERRORS
--

data MnemonicException = FailedToCreateEntropy MnemonicErr
    deriving (Show, Typeable)

instance Exception MnemonicException

data MnemonicErr
    = MnemonicErrUnknownWord
    | MnemonicErrWrongNumberOfWords Int Int
    | MnemonicErrNonASCIIChar
    | MnemonicErrForbiddenMnemonic
    | MnemonicErrChecksumFailed [Bit] [Bit]
    | MnemonicErrInvalidEntropyLength Int
    | MnemonicErrCouldntDecode Text
    deriving (Show)

instance Buildable MnemonicErr where
    build = \case
        MnemonicErrUnknownWord ->
            bprint "Unknown Mnemonic word(s)"
        MnemonicErrWrongNumberOfWords w g ->
            bprint ("Mnemonic must be a list of " % build % " words (got " % build % ")") w g
        MnemonicErrNonASCIIChar ->
            bprint "Mnemonic must use only ASCII characters"
        MnemonicErrForbiddenMnemonic ->
            bprint "Forbidden Mnemonic: an example Mnemonic has been submitted. \
            \Please generate a fresh and private Mnemonic from a trusted source"
        MnemonicErrChecksumFailed w g ->
            bprint ("Mnemonic checksum failed: " % listJson % " vs " % listJson) w g
        MnemonicErrInvalidEntropyLength l ->
            bprint ("Entropy must be a sequence of " % build % " bytes") l
        MnemonicErrCouldntDecode s ->
            bprint ("couldn't decode entropy's bits: " % build) s


--
-- CONSTRUCTORS
--

-- | Smart-constructor for the Entropy
mkEntropy
    :: forall n w. (n ~ WordCountToNat w, KnownNat n)
    => ByteString
    -> Either MnemonicErr (Entropy w)
mkEntropy bytes = do
    let ent = entropyLength (Proxy :: Proxy (Entropy w))
    when ((8 * BS.length bytes) /= ent) $ Left (MnemonicErrInvalidEntropyLength ent)
    Right (Entropy bytes)


-- | Generate Entropy of a given size
genEntropy
    :: forall n w. (n ~ WordCountToNat w, KnownNat n)
    => IO (Entropy w)
genEntropy =
    let
        size =
            fromIntegral (entropyLength (Proxy :: Proxy (Entropy w))) `quot` 8
        eitherToIO =
            either (throwM . FailedToCreateEntropy) return
    in
        (eitherToIO . mkEntropy) =<< Crypto.getEntropy size


-- | Smart-constructor for the Mnemonic
mkMnemonic
    :: forall n w. (n ~ WordCountToNat w, KnownNat n)
    => [Text]
    -> Either MnemonicErr (Mnemonic w)
mkMnemonic wordsm = do
    let n  = fromIntegral $ natVal (Proxy :: Proxy n)
    let n' = length wordsm
    when (n /= n') $
        Left $ MnemonicErrWrongNumberOfWords n n'
    when (isJust $ Text.find (not . isAscii) (unwords wordsm)) $
        Left MnemonicErrNonASCIIChar
    when (wordsm == map snd (mnemonicToWords (def @(Mnemonic 'TwelveWords)))) $
        Left MnemonicErrForbiddenMnemonic
    indices <- findIndices dictionaryEN wordsm
    let ent = entropyLength (Proxy :: Proxy (Entropy w))
    let (entropyBits, checksum) = splitAt ent (toBits indices)
    entropy <- mkEntropy =<< (bimap MnemonicErrCouldntDecode BS.pack (fromBits entropyBits))
    let checksum' = calcChecksum entropy
    when (checksum /= checksum') $
        Left $ MnemonicErrChecksumFailed checksum checksum'
    pure $ Mnemonic
        { mnemonicToEntropy = entropy
        , mnemonicToWords   = zip indices wordsm
        }
  where
    findIndices :: [Text] -> [Text] -> Either MnemonicErr [Word11]
    findIndices es targets =
        case mapM (\e -> elemIndex e es) targets of
            Nothing ->
                Left MnemonicErrUnknownWord
            Just is ->
                pure (map fromIntegral is)


--
-- CONVERSIONS
--

-- | Convert a mnemonic to a seed that can be used to initiate a HD wallet.
-- Note that our current implementation deviates from BIP-39 as:
--
--    - We do not use the password to produce the seed
--    - We rely on a fast blake2b hashing function rather than a slow PKBDF2
--
-- Somehow, we also convert mnemonic to raw bytes using a Blake2b_256 but with
-- a slightly different approach when converting them to aesKey when redeeming
-- paper wallets... In this case, we do not serialize the inputs and outputs.
--
-- For now, we have two use case for that serialization function. When creating
-- an HD wallet seed, in which case, the function we use is `serialize'` from
-- the Pos.Binary module. And, when creating an AESKey seed in which case we
-- simply pass the `identity` function.
mnemonicToSeed :: Mnemonic w -> ByteString
mnemonicToSeed =
    serialize' . blake2b . serialize' . entropyToByteString . mnemonicToEntropy


-- | Convert a mnemonic to a seed AesKey. Almost identical to @MnemonictoSeed@
-- minus the extra serialization.
mnemonicToAESKey :: Mnemonic w -> AesKey
mnemonicToAESKey =
    AesKey . blake2b . entropyToByteString . mnemonicToEntropy


-- | Provide intial entropy as a 'ByteString' of length multiple of 4 bytes.
-- Output a mnemonic sentence.
entropyToMnemonic
    :: forall n w. (n ~ WordCountToNat w, KnownNat n)
    => Entropy w
    -> Mnemonic w
entropyToMnemonic entropy@(Entropy bytes) =
    let
        checksum = calcChecksum entropy
        bits     = toBits (BS.unpack bytes) ++ checksum
        -- Smart-constructors maintain an invariant, fromBits _can't fail_.
        indices  = either (error . ("Invariant failed: " <>)) identity (fromBits bits)
        wordsm   = map (\i -> dictionaryEN !! (fromIntegral i)) indices
    in
        Mnemonic entropy (zip indices wordsm)


--
-- UTILS
--

-- | Get the corresponding Checksum length IN BITS
checksumLength
    :: forall n w. (n ~ WordCountToNat w, KnownNat n)
    => Proxy (Entropy w)
    -> Int
checksumLength _ =
    let
        n = fromIntegral $ natVal (Proxy :: Proxy n)
    in
        (n * 11) `quot` 33


-- | Get the corresponding Entropy's length IN BITS
entropyLength
    :: forall n w. (n ~ WordCountToNat w, KnownNat n)
    => Proxy (Entropy w)
    -> Int
entropyLength =
    (* 32) . checksumLength


--
-- INTERNALS
--

type family WordCountToNat (w :: WordCount) :: Nat where
    WordCountToNat 'NineWords   = 9
    WordCountToNat 'TwelveWords = 12

-- | Compute checksum of a given Entropy. Checksum is a multiple of 4 bits,
-- so we represent it in binary form as a list of Bit.
calcChecksum
    :: forall n w. (n ~ WordCountToNat w, KnownNat n)
    => Entropy w
    -> [Bit]
calcChecksum (Entropy bytes) =
    let
        cs     = checksumLength (Proxy :: Proxy (Entropy w))
        sha256 = convert @(Digest SHA256) . hash $ bytes
    in
        take cs $ toBits $ BS.unpack sha256


-- | Simple Blake2b 256-bit of a ByteString
blake2b :: ByteString -> ByteString
blake2b =
    convert @(Digest Blake2b_256) . hash


-- | Initial seed has to be vector or length multiple of 4 bytes and shorter
-- than 64 bytes. Not that this is good for testing or examples, but probably
-- not for generating truly random Mnemonic words.
--
-- See 'Crypto.Random.Entropy (getEntropy)'
instance (n ~ WordCountToNat w, KnownNat n) => Arbitrary (Entropy w) where
    arbitrary =
        let
            size    = entropyLength (Proxy :: Proxy (Entropy w))
            entropy = mkEntropy . B8.pack <$> vectorOf (size `quot` 8) arbitrary
        in
            either (error . ("Invalid Arbitrary Entropy: " <>) . show) identity <$> entropy


-- Same remark from 'Arbitrary Entropy' applies here.
instance (n ~ WordCountToNat w, KnownNat n) => Arbitrary (Mnemonic w) where
    arbitrary =
        entropyToMnemonic <$> arbitrary


-- FIXME: Suggestion, we could -- when certain flags are turned on -- display
-- a fingerprint of the Mnemonic, like a PKBDF2 over n iterations. This could be
-- useful for debug to know whether two users are using the same mnemonic words
-- and relatively benign EVEN THOUGH, it will permit to somewhat tight requests
-- to a specific identity (since mnemonic words are 'unique', they are supposed
-- to uniquely identify users, hence the privacy issue). For debbugging only and
-- with the user consent, that's something we could do.
instance Buildable (Mnemonic w) where
    build _ =
        "<mnemonic>"

instance Buildable (SecureLog (Mnemonic w)) where
    build _ =
        "<mnemonic>"

-- | To use everytime we need to show an example of a Mnemonic. This particular
-- mnemonic is rejected to prevent users from using it on a real wallet.
instance Default (Mnemonic 'TwelveWords) where
    def = Mnemonic
        { mnemonicToEntropy = Entropy "\211\177\US\"\245\163\233\152\169]\149\DC3\239)\234\172"
        , mnemonicToWords =
            [ (1693,"squirrel")
            , (1095,"material")
            , (1605,"silly")
            , (1882,"twice")
            , (500,"direct")
            , (1634,"slush")
            , (1323,"pistol")
            , (1429,"razor")
            , (159,"become")
            , (970,"junk")
            , (981,"kingdom")
            , (710,"flee")
            ]
        }


instance (n ~ WordCountToNat w, KnownNat n) => FromJSON (Mnemonic w) where
    parseJSON =
        parseJSON >=> (eitherToParser . mkMnemonic)
      where
        eitherToParser :: Either MnemonicErr (Mnemonic w) -> Parser (Mnemonic w)
        eitherToParser =
            either (fail . show) pure


instance ToJSON (Mnemonic w) where
    toJSON =
        toJSON . map snd . mnemonicToWords


instance (n ~ WordCountToNat w, KnownNat n) => ToSchema (Mnemonic w) where
    declareNamedSchema _ = do
        let n = natVal (Proxy :: Proxy n)
        NamedSchema _ schema <- declareNamedSchema (Proxy @[Text])
        return $ NamedSchema (Just "Mnemonic") schema
            & minItems ?~ n
            & maxItems ?~ n


dictionaryEN :: [Text]
dictionaryEN =
    [ "abandon", "ability", "able", "about", "above", "absent"
    , "absorb", "abstract", "absurd", "abuse", "access", "accident"
    , "account", "accuse", "achieve", "acid", "acoustic", "acquire"
    , "across", "act", "action", "actor", "actress", "actual"
    , "adapt", "add", "addict", "address", "adjust", "admit"
    , "adult", "advance", "advice", "aerobic", "affair", "afford"
    , "afraid", "again", "age", "agent", "agree", "ahead"
    , "aim", "air", "airport", "aisle", "alarm", "album"
    , "alcohol", "alert", "alien", "all", "alley", "allow"
    , "almost", "alone", "alpha", "already", "also", "alter"
    , "always", "amateur", "amazing", "among", "amount", "amused"
    , "analyst", "anchor", "ancient", "anger", "angle", "angry"
    , "animal", "ankle", "announce", "annual", "another", "answer"
    , "antenna", "antique", "anxiety", "any", "apart", "apology"
    , "appear", "apple", "approve", "april", "arch", "arctic"
    , "area", "arena", "argue", "arm", "armed", "armor"
    , "army", "around", "arrange", "arrest", "arrive", "arrow"
    , "art", "artefact", "artist", "artwork", "ask", "aspect"
    , "assault", "asset", "assist", "assume", "asthma", "athlete"
    , "atom", "attack", "attend", "attitude", "attract", "auction"
    , "audit", "august", "aunt", "author", "auto", "autumn"
    , "average", "avocado", "avoid", "awake", "aware", "away"
    , "awesome", "awful", "awkward", "axis", "baby", "bachelor"
    , "bacon", "badge", "bag", "balance", "balcony", "ball"
    , "bamboo", "banana", "banner", "bar", "barely", "bargain"
    , "barrel", "base", "basic", "basket", "battle", "beach"
    , "bean", "beauty", "because", "become", "beef", "before"
    , "begin", "behave", "behind", "believe", "below", "belt"
    , "bench", "benefit", "best", "betray", "better", "between"
    , "beyond", "bicycle", "bid", "bike", "bind", "biology"
    , "bird", "birth", "bitter", "black", "blade", "blame"
    , "blanket", "blast", "bleak", "bless", "blind", "blood"
    , "blossom", "blouse", "blue", "blur", "blush", "board"
    , "boat", "body", "boil", "bomb", "bone", "bonus"
    , "book", "boost", "border", "boring", "borrow", "boss"
    , "bottom", "bounce", "box", "boy", "bracket", "brain"
    , "brand", "brass", "brave", "bread", "breeze", "brick"
    , "bridge", "brief", "bright", "bring", "brisk", "broccoli"
    , "broken", "bronze", "broom", "brother", "brown", "brush"
    , "bubble", "buddy", "budget", "buffalo", "build", "bulb"
    , "bulk", "bullet", "bundle", "bunker", "burden", "burger"
    , "burst", "bus", "business", "busy", "butter", "buyer"
    , "buzz", "cabbage", "cabin", "cable", "cactus", "cage"
    , "cake", "call", "calm", "camera", "camp", "can"
    , "canal", "cancel", "candy", "cannon", "canoe", "canvas"
    , "canyon", "capable", "capital", "captain", "car", "carbon"
    , "card", "cargo", "carpet", "carry", "cart", "case"
    , "cash", "casino", "castle", "casual", "cat", "catalog"
    , "catch", "category", "cattle", "caught", "cause", "caution"
    , "cave", "ceiling", "celery", "cement", "census", "century"
    , "cereal", "certain", "chair", "chalk", "champion", "change"
    , "chaos", "chapter", "charge", "chase", "chat", "cheap"
    , "check", "cheese", "chef", "cherry", "chest", "chicken"
    , "chief", "child", "chimney", "choice", "choose", "chronic"
    , "chuckle", "chunk", "churn", "cigar", "cinnamon", "circle"
    , "citizen", "city", "civil", "claim", "clap", "clarify"
    , "claw", "clay", "clean", "clerk", "clever", "click"
    , "client", "cliff", "climb", "clinic", "clip", "clock"
    , "clog", "close", "cloth", "cloud", "clown", "club"
    , "clump", "cluster", "clutch", "coach", "coast", "coconut"
    , "code", "coffee", "coil", "coin", "collect", "color"
    , "column", "combine", "come", "comfort", "comic", "common"
    , "company", "concert", "conduct", "confirm", "congress", "connect"
    , "consider", "control", "convince", "cook", "cool", "copper"
    , "copy", "coral", "core", "corn", "correct", "cost"
    , "cotton", "couch", "country", "couple", "course", "cousin"
    , "cover", "coyote", "crack", "cradle", "craft", "cram"
    , "crane", "crash", "crater", "crawl", "crazy", "cream"
    , "credit", "creek", "crew", "cricket", "crime", "crisp"
    , "critic", "crop", "cross", "crouch", "crowd", "crucial"
    , "cruel", "cruise", "crumble", "crunch", "crush", "cry"
    , "crystal", "cube", "culture", "cup", "cupboard", "curious"
    , "current", "curtain", "curve", "cushion", "custom", "cute"
    , "cycle", "dad", "damage", "damp", "dance", "danger"
    , "daring", "dash", "daughter", "dawn", "day", "deal"
    , "debate", "debris", "decade", "december", "decide", "decline"
    , "decorate", "decrease", "deer", "defense", "define", "defy"
    , "degree", "delay", "deliver", "demand", "demise", "denial"
    , "dentist", "deny", "depart", "depend", "deposit", "depth"
    , "deputy", "derive", "describe", "desert", "design", "desk"
    , "despair", "destroy", "detail", "detect", "develop", "device"
    , "devote", "diagram", "dial", "diamond", "diary", "dice"
    , "diesel", "diet", "differ", "digital", "dignity", "dilemma"
    , "dinner", "dinosaur", "direct", "dirt", "disagree", "discover"
    , "disease", "dish", "dismiss", "disorder", "display", "distance"
    , "divert", "divide", "divorce", "dizzy", "doctor", "document"
    , "dog", "doll", "dolphin", "domain", "donate", "donkey"
    , "donor", "door", "dose", "double", "dove", "draft"
    , "dragon", "drama", "drastic", "draw", "dream", "dress"
    , "drift", "drill", "drink", "drip", "drive", "drop"
    , "drum", "dry", "duck", "dumb", "dune", "during"
    , "dust", "dutch", "duty", "dwarf", "dynamic", "eager"
    , "eagle", "early", "earn", "earth", "easily", "east"
    , "easy", "echo", "ecology", "economy", "edge", "edit"
    , "educate", "effort", "egg", "eight", "either", "elbow"
    , "elder", "electric", "elegant", "element", "elephant", "elevator"
    , "elite", "else", "embark", "embody", "embrace", "emerge"
    , "emotion", "employ", "empower", "empty", "enable", "enact"
    , "end", "endless", "endorse", "enemy", "energy", "enforce"
    , "engage", "engine", "enhance", "enjoy", "enlist", "enough"
    , "enrich", "enroll", "ensure", "enter", "entire", "entry"
    , "envelope", "episode", "equal", "equip", "era", "erase"
    , "erode", "erosion", "error", "erupt", "escape", "essay"
    , "essence", "estate", "eternal", "ethics", "evidence", "evil"
    , "evoke", "evolve", "exact", "example", "excess", "exchange"
    , "excite", "exclude", "excuse", "execute", "exercise", "exhaust"
    , "exhibit", "exile", "exist", "exit", "exotic", "expand"
    , "expect", "expire", "explain", "expose", "express", "extend"
    , "extra", "eye", "eyebrow", "fabric", "face", "faculty"
    , "fade", "faint", "faith", "fall", "false", "fame"
    , "family", "famous", "fan", "fancy", "fantasy", "farm"
    , "fashion", "fat", "fatal", "father", "fatigue", "fault"
    , "favorite", "feature", "february", "federal", "fee", "feed"
    , "feel", "female", "fence", "festival", "fetch", "fever"
    , "few", "fiber", "fiction", "field", "figure", "file"
    , "film", "filter", "final", "find", "fine", "finger"
    , "finish", "fire", "firm", "first", "fiscal", "fish"
    , "fit", "fitness", "fix", "flag", "flame", "flash"
    , "flat", "flavor", "flee", "flight", "flip", "float"
    , "flock", "floor", "flower", "fluid", "flush", "fly"
    , "foam", "focus", "fog", "foil", "fold", "follow"
    , "food", "foot", "force", "forest", "forget", "fork"
    , "fortune", "forum", "forward", "fossil", "foster", "found"
    , "fox", "fragile", "frame", "frequent", "fresh", "friend"
    , "fringe", "frog", "front", "frost", "frown", "frozen"
    , "fruit", "fuel", "fun", "funny", "furnace", "fury"
    , "future", "gadget", "gain", "galaxy", "gallery", "game"
    , "gap", "garage", "garbage", "garden", "garlic", "garment"
    , "gas", "gasp", "gate", "gather", "gauge", "gaze"
    , "general", "genius", "genre", "gentle", "genuine", "gesture"
    , "ghost", "giant", "gift", "giggle", "ginger", "giraffe"
    , "girl", "give", "glad", "glance", "glare", "glass"
    , "glide", "glimpse", "globe", "gloom", "glory", "glove"
    , "glow", "glue", "goat", "goddess", "gold", "good"
    , "goose", "gorilla", "gospel", "gossip", "govern", "gown"
    , "grab", "grace", "grain", "grant", "grape", "grass"
    , "gravity", "great", "green", "grid", "grief", "grit"
    , "grocery", "group", "grow", "grunt", "guard", "guess"
    , "guide", "guilt", "guitar", "gun", "gym", "habit"
    , "hair", "half", "hammer", "hamster", "hand", "happy"
    , "harbor", "hard", "harsh", "harvest", "hat", "have"
    , "hawk", "hazard", "head", "health", "heart", "heavy"
    , "hedgehog", "height", "hello", "helmet", "help", "hen"
    , "hero", "hidden", "high", "hill", "hint", "hip"
    , "hire", "history", "hobby", "hockey", "hold", "hole"
    , "holiday", "hollow", "home", "honey", "hood", "hope"
    , "horn", "horror", "horse", "hospital", "host", "hotel"
    , "hour", "hover", "hub", "huge", "human", "humble"
    , "humor", "hundred", "hungry", "hunt", "hurdle", "hurry"
    , "hurt", "husband", "hybrid", "ice", "icon", "idea"
    , "identify", "idle", "ignore", "ill", "illegal", "illness"
    , "image", "imitate", "immense", "immune", "impact", "impose"
    , "improve", "impulse", "inch", "include", "income", "increase"
    , "index", "indicate", "indoor", "industry", "infant", "inflict"
    , "inform", "inhale", "inherit", "initial", "inject", "injury"
    , "inmate", "inner", "innocent", "input", "inquiry", "insane"
    , "insect", "inside", "inspire", "install", "intact", "interest"
    , "into", "invest", "invite", "involve", "iron", "island"
    , "isolate", "issue", "item", "ivory", "jacket", "jaguar"
    , "jar", "jazz", "jealous", "jeans", "jelly", "jewel"
    , "job", "join", "joke", "journey", "joy", "judge"
    , "juice", "jump", "jungle", "junior", "junk", "just"
    , "kangaroo", "keen", "keep", "ketchup", "key", "kick"
    , "kid", "kidney", "kind", "kingdom", "kiss", "kit"
    , "kitchen", "kite", "kitten", "kiwi", "knee", "knife"
    , "knock", "know", "lab", "label", "labor", "ladder"
    , "lady", "lake", "lamp", "language", "laptop", "large"
    , "later", "latin", "laugh", "laundry", "lava", "law"
    , "lawn", "lawsuit", "layer", "lazy", "leader", "leaf"
    , "learn", "leave", "lecture", "left", "leg", "legal"
    , "legend", "leisure", "lemon", "lend", "length", "lens"
    , "leopard", "lesson", "letter", "level", "liar", "liberty"
    , "library", "license", "life", "lift", "light", "like"
    , "limb", "limit", "link", "lion", "liquid", "list"
    , "little", "live", "lizard", "load", "loan", "lobster"
    , "local", "lock", "logic", "lonely", "long", "loop"
    , "lottery", "loud", "lounge", "love", "loyal", "lucky"
    , "luggage", "lumber", "lunar", "lunch", "luxury", "lyrics"
    , "machine", "mad", "magic", "magnet", "maid", "mail"
    , "main", "major", "make", "mammal", "man", "manage"
    , "mandate", "mango", "mansion", "manual", "maple", "marble"
    , "march", "margin", "marine", "market", "marriage", "mask"
    , "mass", "master", "match", "material", "math", "matrix"
    , "matter", "maximum", "maze", "meadow", "mean", "measure"
    , "meat", "mechanic", "medal", "media", "melody", "melt"
    , "member", "memory", "mention", "menu", "mercy", "merge"
    , "merit", "merry", "mesh", "message", "metal", "method"
    , "middle", "midnight", "milk", "million", "mimic", "mind"
    , "minimum", "minor", "minute", "miracle", "mirror", "misery"
    , "miss", "mistake", "mix", "mixed", "mixture", "mobile"
    , "model", "modify", "mom", "moment", "monitor", "monkey"
    , "monster", "month", "moon", "moral", "more", "morning"
    , "mosquito", "mother", "motion", "motor", "mountain", "mouse"
    , "move", "movie", "much", "muffin", "mule", "multiply"
    , "muscle", "museum", "mushroom", "music", "must", "mutual"
    , "myself", "mystery", "myth", "naive", "name", "napkin"
    , "narrow", "nasty", "nation", "nature", "near", "neck"
    , "need", "negative", "neglect", "neither", "nephew", "nerve"
    , "nest", "net", "network", "neutral", "never", "news"
    , "next", "nice", "night", "noble", "noise", "nominee"
    , "noodle", "normal", "north", "nose", "notable", "note"
    , "nothing", "notice", "novel", "now", "nuclear", "number"
    , "nurse", "nut", "oak", "obey", "object", "oblige"
    , "obscure", "observe", "obtain", "obvious", "occur", "ocean"
    , "october", "odor", "off", "offer", "office", "often"
    , "oil", "okay", "old", "olive", "olympic", "omit"
    , "once", "one", "onion", "online", "only", "open"
    , "opera", "opinion", "oppose", "option", "orange", "orbit"
    , "orchard", "order", "ordinary", "organ", "orient", "original"
    , "orphan", "ostrich", "other", "outdoor", "outer", "output"
    , "outside", "oval", "oven", "over", "own", "owner"
    , "oxygen", "oyster", "ozone", "pact", "paddle", "page"
    , "pair", "palace", "palm", "panda", "panel", "panic"
    , "panther", "paper", "parade", "parent", "park", "parrot"
    , "party", "pass", "patch", "path", "patient", "patrol"
    , "pattern", "pause", "pave", "payment", "peace", "peanut"
    , "pear", "peasant", "pelican", "pen", "penalty", "pencil"
    , "people", "pepper", "perfect", "permit", "person", "pet"
    , "phone", "photo", "phrase", "physical", "piano", "picnic"
    , "picture", "piece", "pig", "pigeon", "pill", "pilot"
    , "pink", "pioneer", "pipe", "pistol", "pitch", "pizza"
    , "place", "planet", "plastic", "plate", "play", "please"
    , "pledge", "pluck", "plug", "plunge", "poem", "poet"
    , "point", "polar", "pole", "police", "pond", "pony"
    , "pool", "popular", "portion", "position", "possible", "post"
    , "potato", "pottery", "poverty", "powder", "power", "practice"
    , "praise", "predict", "prefer", "prepare", "present", "pretty"
    , "prevent", "price", "pride", "primary", "print", "priority"
    , "prison", "private", "prize", "problem", "process", "produce"
    , "profit", "program", "project", "promote", "proof", "property"
    , "prosper", "protect", "proud", "provide", "public", "pudding"
    , "pull", "pulp", "pulse", "pumpkin", "punch", "pupil"
    , "puppy", "purchase", "purity", "purpose", "purse", "push"
    , "put", "puzzle", "pyramid", "quality", "quantum", "quarter"
    , "question", "quick", "quit", "quiz", "quote", "rabbit"
    , "raccoon", "race", "rack", "radar", "radio", "rail"
    , "rain", "raise", "rally", "ramp", "ranch", "random"
    , "range", "rapid", "rare", "rate", "rather", "raven"
    , "raw", "razor", "ready", "real", "reason", "rebel"
    , "rebuild", "recall", "receive", "recipe", "record", "recycle"
    , "reduce", "reflect", "reform", "refuse", "region", "regret"
    , "regular", "reject", "relax", "release", "relief", "rely"
    , "remain", "remember", "remind", "remove", "render", "renew"
    , "rent", "reopen", "repair", "repeat", "replace", "report"
    , "require", "rescue", "resemble", "resist", "resource", "response"
    , "result", "retire", "retreat", "return", "reunion", "reveal"
    , "review", "reward", "rhythm", "rib", "ribbon", "rice"
    , "rich", "ride", "ridge", "rifle", "right", "rigid"
    , "ring", "riot", "ripple", "risk", "ritual", "rival"
    , "river", "road", "roast", "robot", "robust", "rocket"
    , "romance", "roof", "rookie", "room", "rose", "rotate"
    , "rough", "round", "route", "royal", "rubber", "rude"
    , "rug", "rule", "run", "runway", "rural", "sad"
    , "saddle", "sadness", "safe", "sail", "salad", "salmon"
    , "salon", "salt", "salute", "same", "sample", "sand"
    , "satisfy", "satoshi", "sauce", "sausage", "save", "say"
    , "scale", "scan", "scare", "scatter", "scene", "scheme"
    , "school", "science", "scissors", "scorpion", "scout", "scrap"
    , "screen", "script", "scrub", "sea", "search", "season"
    , "seat", "second", "secret", "section", "security", "seed"
    , "seek", "segment", "select", "sell", "seminar", "senior"
    , "sense", "sentence", "series", "service", "session", "settle"
    , "setup", "seven", "shadow", "shaft", "shallow", "share"
    , "shed", "shell", "sheriff", "shield", "shift", "shine"
    , "ship", "shiver", "shock", "shoe", "shoot", "shop"
    , "short", "shoulder", "shove", "shrimp", "shrug", "shuffle"
    , "shy", "sibling", "sick", "side", "siege", "sight"
    , "sign", "silent", "silk", "silly", "silver", "similar"
    , "simple", "since", "sing", "siren", "sister", "situate"
    , "six", "size", "skate", "sketch", "ski", "skill"
    , "skin", "skirt", "skull", "slab", "slam", "sleep"
    , "slender", "slice", "slide", "slight", "slim", "slogan"
    , "slot", "slow", "slush", "small", "smart", "smile"
    , "smoke", "smooth", "snack", "snake", "snap", "sniff"
    , "snow", "soap", "soccer", "social", "sock", "soda"
    , "soft", "solar", "soldier", "solid", "solution", "solve"
    , "someone", "song", "soon", "sorry", "sort", "soul"
    , "sound", "soup", "source", "south", "space", "spare"
    , "spatial", "spawn", "speak", "special", "speed", "spell"
    , "spend", "sphere", "spice", "spider", "spike", "spin"
    , "spirit", "split", "spoil", "sponsor", "spoon", "sport"
    , "spot", "spray", "spread", "spring", "spy", "square"
    , "squeeze", "squirrel", "stable", "stadium", "staff", "stage"
    , "stairs", "stamp", "stand", "start", "state", "stay"
    , "steak", "steel", "stem", "step", "stereo", "stick"
    , "still", "sting", "stock", "stomach", "stone", "stool"
    , "story", "stove", "strategy", "street", "strike", "strong"
    , "struggle", "student", "stuff", "stumble", "style", "subject"
    , "submit", "subway", "success", "such", "sudden", "suffer"
    , "sugar", "suggest", "suit", "summer", "sun", "sunny"
    , "sunset", "super", "supply", "supreme", "sure", "surface"
    , "surge", "surprise", "surround", "survey", "suspect", "sustain"
    , "swallow", "swamp", "swap", "swarm", "swear", "sweet"
    , "swift", "swim", "swing", "switch", "sword", "symbol"
    , "symptom", "syrup", "system", "table", "tackle", "tag"
    , "tail", "talent", "talk", "tank", "tape", "target"
    , "task", "taste", "tattoo", "taxi", "teach", "team"
    , "tell", "ten", "tenant", "tennis", "tent", "term"
    , "test", "text", "thank", "that", "theme", "then"
    , "theory", "there", "they", "thing", "this", "thought"
    , "three", "thrive", "throw", "thumb", "thunder", "ticket"
    , "tide", "tiger", "tilt", "timber", "time", "tiny"
    , "tip", "tired", "tissue", "title", "toast", "tobacco"
    , "today", "toddler", "toe", "together", "toilet", "token"
    , "tomato", "tomorrow", "tone", "tongue", "tonight", "tool"
    , "tooth", "top", "topic", "topple", "torch", "tornado"
    , "tortoise", "toss", "total", "tourist", "toward", "tower"
    , "town", "toy", "track", "trade", "traffic", "tragic"
    , "train", "transfer", "trap", "trash", "travel", "tray"
    , "treat", "tree", "trend", "trial", "tribe", "trick"
    , "trigger", "trim", "trip", "trophy", "trouble", "truck"
    , "true", "truly", "trumpet", "trust", "truth", "try"
    , "tube", "tuition", "tumble", "tuna", "tunnel", "turkey"
    , "turn", "turtle", "twelve", "twenty", "twice", "twin"
    , "twist", "two", "type", "typical", "ugly", "umbrella"
    , "unable", "unaware", "uncle", "uncover", "under", "undo"
    , "unfair", "unfold", "unhappy", "uniform", "unique", "unit"
    , "universe", "unknown", "unlock", "until", "unusual", "unveil"
    , "update", "upgrade", "uphold", "upon", "upper", "upset"
    , "urban", "urge", "usage", "use", "used", "useful"
    , "useless", "usual", "utility", "vacant", "vacuum", "vague"
    , "valid", "valley", "valve", "van", "vanish", "vapor"
    , "various", "vast", "vault", "vehicle", "velvet", "vendor"
    , "venture", "venue", "verb", "verify", "version", "very"
    , "vessel", "veteran", "viable", "vibrant", "vicious", "victory"
    , "video", "view", "village", "vintage", "violin", "virtual"
    , "virus", "visa", "visit", "visual", "vital", "vivid"
    , "vocal", "voice", "void", "volcano", "volume", "vote"
    , "voyage", "wage", "wagon", "wait", "walk", "wall"
    , "walnut", "want", "warfare", "warm", "warrior", "wash"
    , "wasp", "waste", "water", "wave", "way", "wealth"
    , "weapon", "wear", "weasel", "weather", "web", "wedding"
    , "weekend", "weird", "welcome", "west", "wet", "whale"
    , "what", "wheat", "wheel", "when", "where", "whip"
    , "whisper", "wide", "width", "wife", "wild", "will"
    , "win", "window", "wine", "wing", "wink", "winner"
    , "winter", "wire", "wisdom", "wise", "wish", "witness"
    , "wolf", "woman", "wonder", "wood", "wool", "word"
    , "work", "world", "worry", "worth", "wrap", "wreck"
    , "wrestle", "wrist", "write", "wrong", "yard", "year"
    , "yellow", "you", "young", "youth", "zebra", "zero"
    , "zone", "zoo"
    ]
