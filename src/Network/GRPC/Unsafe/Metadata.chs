{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}

module Network.GRPC.Unsafe.Metadata where

import Control.Exception
import Control.Monad
import Data.ByteString (ByteString, useAsCString, packCString)
import Data.Function (on)
import Data.List (sortBy, groupBy)
import qualified Data.SortedList as SL
import qualified Data.Map.Strict as M
import Data.Ord (comparing)
import Foreign.C.String
import Foreign.Ptr
import Foreign.Storable
import GHC.Exts

#include <grpc/grpc.h>
#include <grpc/status.h>
#include <grpc/impl/codegen/grpc_types.h>
#include <grpc_haskell.h>

-- | Represents metadata for a given RPC, consisting of key-value pairs. Keys
-- are allowed to be repeated. Since repeated keys are unlikely in practice,
-- the 'IsList' instance uses key-value pairs as items. For example,
-- @fromList [("key1","val1"),("key2","val2"),("key1","val3")]@.
newtype MetadataMap = MetadataMap {unMap :: M.Map ByteString (SL.SortedList ByteString)}
  deriving Eq


instance Show MetadataMap where
  show m = "fromList " ++ show (M.toList (unMap m))

instance Monoid MetadataMap where
  mempty = MetadataMap $ M.empty
  mappend (MetadataMap m1) (MetadataMap m2) =
    MetadataMap $ M.unionWith mappend m1 m2

instance IsList MetadataMap where
  type Item MetadataMap = (ByteString, ByteString)
  fromList = MetadataMap
             . M.fromList
             . map (\xs -> ((fst . head) xs, fromList $ map snd xs))
             . groupBy ((==) `on` fst)
             . sortBy (comparing fst)
  toList = concatMap (\(k,vs) -> map (k,) vs)
           . map (fmap toList)
           . M.toList
           . unMap

-- | Represents a pointer to one or more metadata key/value pairs. This type
-- is intended to be used when sending metadata.
{#pointer *grpc_metadata as MetadataKeyValPtr newtype#}

deriving instance Show MetadataKeyValPtr

-- | Represents a pointer to a grpc_metadata_array. Must be destroyed with
-- 'metadataArrayDestroy'. This type is intended for receiving metadata.
-- This can be populated by passing it to e.g. 'grpcServerRequestCall'.
{#pointer *grpc_metadata_array as MetadataArray newtype#}

deriving instance Show MetadataArray

{#fun unsafe metadata_array_get_metadata as ^
  {`MetadataArray'} -> `MetadataKeyValPtr'#}

-- | Overwrites the metadata in the given 'MetadataArray'. The given
-- 'MetadataKeyValPtr' *must* have been created with 'createMetadata' in this
-- module.
{#fun unsafe metadata_array_set_metadata as ^
  {`MetadataArray', `MetadataKeyValPtr'} -> `()'#}

{#fun unsafe metadata_array_get_count as ^ {`MetadataArray'} -> `Int'#}

{#fun unsafe metadata_array_get_capacity as ^ {`MetadataArray'} -> `Int'#}

instance Storable MetadataArray where
  sizeOf (MetadataArray r) = sizeOf r
  alignment (MetadataArray r) = alignment r
  peek p = fmap MetadataArray (peek (castPtr p))
  poke p (MetadataArray r) = poke (castPtr p) r

-- | Create an empty 'MetadataArray'. Returns a pointer to it so that we can
-- pass it to the appropriate op creation functions.
{#fun unsafe metadata_array_create as ^ {} -> `Ptr MetadataArray' id#}

{#fun unsafe metadata_array_destroy as ^ {id `Ptr MetadataArray'} -> `()'#}

-- Note: I'm pretty sure we must call out to C to allocate these
-- because they are nested structs.
-- | Allocates space for exactly n metadata key/value pairs.
{#fun unsafe metadata_alloc as ^ {`Int'} -> `MetadataKeyValPtr'#}

{#fun unsafe metadata_free as ^ {`MetadataKeyValPtr'} -> `()'#}

-- | Sets a metadata key/value pair at the given index in the
-- 'MetadataKeyValPtr'. No error checking is performed to ensure the index is
-- in bounds!
{#fun unsafe set_metadata_key_val as setMetadataKeyVal
  {useAsCString* `ByteString', useAsCString* `ByteString',
   `MetadataKeyValPtr', `Int'} -> `()'#}

{#fun unsafe get_metadata_key as getMetadataKey'
  {`MetadataKeyValPtr', `Int'} -> `CString'#}

{#fun unsafe get_metadata_val as getMetadataVal'
  {`MetadataKeyValPtr', `Int'} -> `CString'#}

--TODO: The test suggests this is leaking.
withMetadataArrayPtr :: (Ptr MetadataArray -> IO a) -> IO a
withMetadataArrayPtr = bracket metadataArrayCreate metadataArrayDestroy

withMetadataKeyValPtr :: Int -> (MetadataKeyValPtr -> IO a) -> IO a
withMetadataKeyValPtr i f = bracket (metadataAlloc i) metadataFree f

getMetadataKey :: MetadataKeyValPtr -> Int -> IO ByteString
getMetadataKey m = getMetadataKey' m >=> packCString

getMetadataVal :: MetadataKeyValPtr -> Int -> IO ByteString
getMetadataVal m = getMetadataVal' m >=> packCString

createMetadata :: MetadataMap -> IO MetadataKeyValPtr
createMetadata m = do
  let indexedKeyVals = zip [0..] $ toList m
      l = length indexedKeyVals
  metadata <- metadataAlloc l
  forM_ indexedKeyVals $ \(i,(k,v)) -> setMetadataKeyVal k v metadata i
  return metadata

getAllMetadataArray :: MetadataArray -> IO MetadataMap
getAllMetadataArray m = do
  kvs <- metadataArrayGetMetadata m
  l <- metadataArrayGetCount m
  getAllMetadata kvs l

getAllMetadata :: MetadataKeyValPtr -> Int -> IO MetadataMap
getAllMetadata m count = do
  let indices = [0..count-1]
  fmap fromList $ forM indices $
    \i -> liftM2 (,) (getMetadataKey m i) (getMetadataVal m i)
