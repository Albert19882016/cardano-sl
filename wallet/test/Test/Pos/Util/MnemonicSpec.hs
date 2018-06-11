{-# LANGUAGE DataKinds #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Test.Pos.Util.MnemonicSpec where

import           Universum

import           Crypto.Hash (Blake2b_256, Digest, hash)
import           Data.ByteArray (convert)
import           Data.Default (def)
import           Data.Set (Set)
import           Test.Hspec (Spec, describe, it, shouldSatisfy, xit)
import           Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import           Test.QuickCheck (Arbitrary (..), forAll, property, (===))
import           Test.QuickCheck.Gen (vectorOf)

import           Pos.Crypto (AesKey (..), EncryptedSecretKey, PassPhrase (..),
                             safeDeterministicKeyGen)
import           Pos.Util.Mnemonic (Entropy, Mnemonic, MnemonicErr, WordCount (..),
                                    entropyToByteString, entropyToMnemonic, mkEntropy, mkMnemonic,
                                    mnemonicToAESKey, mnemonicToEntropy, mnemonicToSeed)
import           Pos.Wallet.Web.ClientTypes.Functions (encToCId)
import           Pos.Wallet.Web.ClientTypes.Types (CId)

import qualified Cardano.Crypto.Wallet as CC
import qualified Data.Aeson as Aeson
import qualified Data.Set as Set
import qualified Test.Pos.Util.BackupPhraseOld as Old
import qualified Test.Pos.Util.MnemonicOld as Old


-- | By default, private keys aren't comparable for security reasons (timing
-- attacks). We allow it here for testing purpose which is fine.
instance Eq CC.XPrv where
    (==) = (==) `on` CC.unXPrv



spec :: Spec
spec = do
    describe "Old and New implementation behave identically" $ do
        modifyMaxSuccess (const 100) $ prop "entropyToESK (no passphrase)" $
            \ent -> entropyToESK mempty ent === entropyToESKOld mempty ent

        modifyMaxSuccess (const 100) $ prop "entropyToESK (with passphrase)" $
            \ent -> entropyToESK defPwd ent === entropyToESKOld defPwd ent

        modifyMaxSuccess (const 1000) $ prop "entropyToAESKEy" $
            \ent -> entropyToAESKey ent === entropyToAESKeyOld ent

    modifyMaxSuccess (const 1000) $ prop "(9) entropyToMnemonic . mnemonicToEntropy == identity" $
        \e -> (mnemonicToEntropy . entropyToMnemonic9) e == e

    modifyMaxSuccess (const 1000) $ prop "(12) entropyToMnemonic . mnemonicToEntropy == identity" $
        \e -> (mnemonicToEntropy . entropyToMnemonic12) e == e

    it "No example mnemonic" $
        (mkMnemonic defMnemonic :: Either MnemonicErr (Mnemonic 'TwelveWords)) `shouldSatisfy` isLeft

    it "No empty mnemonic" $
        (mkMnemonic [] :: Either MnemonicErr (Mnemonic 'TwelveWords)) `shouldSatisfy` isLeft

    it "No empty entropy" $
        (mkEntropy "" :: Either MnemonicErr(Entropy 'TwelveWords)) `shouldSatisfy` isLeft

    xit "entropyToWalletId is injective (very long to run, used for investigation)"
        $ property
        $ forAll (vectorOf 1000 arbitrary)
        $ \inputs -> length (inject entropyToWalletId inputs) == length inputs
  where
    entropyToMnemonic9 :: Entropy 'NineWords -> Mnemonic 'NineWords
    entropyToMnemonic9 =
        entropyToMnemonic

    entropyToMnemonic12 :: Entropy 'TwelveWords -> Mnemonic 'TwelveWords
    entropyToMnemonic12 =
        entropyToMnemonic

    defPwd :: PassPhrase
    defPwd =
        PassPhrase "cardano"

    defMnemonic :: [Text]
    defMnemonic = either (error . show) identity
        $ Aeson.eitherDecode
        $ Aeson.encode
        $ def @(Mnemonic 'TwelveWords)

    -- | Collect function results in a Set
    inject :: Ord b => (a -> b) -> [a] -> Set b
    inject fn =
        Set.fromList . fmap fn

    entropyToWalletId :: Entropy 'TwelveWords -> CId w
    entropyToWalletId =
        encToCId . entropyToESK mempty

    blake2b :: ByteString -> ByteString
    blake2b =
        convert @(Digest Blake2b_256) . hash

    -- | Generate an EncryptedSecretKey using the old implementation
    entropyToESKOld :: PassPhrase -> Entropy 'TwelveWords -> EncryptedSecretKey
    entropyToESKOld passphrase ent = esk
      where
        backupPhrase = either
            (error . (<>) "[Old] Wrong arbitrary Entropy generated: " . show)
            (Old.BackupPhrase . words)
            (Old.toMnemonic $ entropyToByteString ent)

        esk = either
            (error . (<>) "[Old] Couldn't create keys from generated BackupPhrase" . show)
            fst
            (Old.safeKeysFromPhrase passphrase backupPhrase)

    -- | Generate an EncryptedSecretKey using the revised implementation
    entropyToESK :: PassPhrase -> Entropy 'TwelveWords -> EncryptedSecretKey
    entropyToESK passphrase ent = esk
      where
        seed =
            mnemonicToSeed $ entropyToMnemonic ent

        esk =
            snd (safeDeterministicKeyGen seed passphrase)

    entropyToAESKeyOld :: Entropy 'NineWords -> AesKey
    entropyToAESKeyOld ent = key
      where
        backupPhrase = either
            (error . (<>) "[Old] Wrong arbitrary Entropy generated: " . show)
            (Old.BackupPhrase . words)
            (Old.toMnemonic $ entropyToByteString ent)

        key = either
            (error . (<>) "[Old] Couldn't create AES keys from generated BackupPhrase" . show)
            identity
            (AesKey . blake2b <$> Old.toSeed backupPhrase)

    entropyToAESKey :: Entropy 'NineWords -> AesKey
    entropyToAESKey =
        mnemonicToAESKey . entropyToMnemonic
