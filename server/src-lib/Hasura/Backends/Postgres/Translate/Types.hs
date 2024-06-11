{-# LANGUAGE UndecidableInstances #-}

-- | Postgres Translate Types
--
-- Intermediary / helper types used for translating IR to Postgres SQL.
module Hasura.Backends.Postgres.Translate.Types
  ( ApplySortingAndSlicing (ApplySortingAndSlicing),
    ArrayConnectionSource (ArrayConnectionSource, _acsSource),
    ArrayRelationSource (ArrayRelationSource),
    ComputedFieldTableSetSource (ComputedFieldTableSetSource),
    CustomSQLCTEs (..),
    NativeQueryFreshIdStore (..),
    initialNativeQueryFreshIdStore,
    DistinctAndOrderByExpr (ASorting),
    JoinTree (..),
    MultiRowSelectNode (..),
    ObjectRelationSource (..),
    ObjectSelectSource (ObjectSelectSource, _ossPrefix),
    PermissionLimitSubQuery (..),
    SelectNode (SelectNode),
    SelectSlicing (SelectSlicing, _ssLimit, _ssOffset),
    SelectSorting (..),
    SelectSource (SelectSource, _ssPrefix),
    SortingAndSlicing (SortingAndSlicing),
    SourcePrefixes (..),
    SimilarArrayFields,
    SelectWriter (..),
    applySortingAndSlicing,
    noSortingAndSlicing,
    objectSelectSourceToSelectSource,
    orderByForJsonAgg,
  )
where

import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int64)
import Hasura.Backends.Postgres.SQL.DML qualified as Postgres
import Hasura.Backends.Postgres.SQL.Types qualified as Postgres
import Hasura.NativeQuery.Metadata (InterpolatedQuery)
import Hasura.Prelude
import Hasura.RQL.IR.Select
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.Relationships.Local (Nullable)

data SourcePrefixes = SourcePrefixes
  { -- | Current source prefix
    _pfThis :: Postgres.Identifier,
    -- | Base table source row identifier to generate
    -- the table's column identifiers for computed field
    -- function input parameters
    _pfBase :: Postgres.Identifier
  }
  deriving (Show, Eq, Generic)

instance Hashable SourcePrefixes

-- | Select portion of rows generated by the query using limit and offset
data SelectSlicing = SelectSlicing
  { _ssLimit :: Maybe Int,
    _ssOffset :: Maybe Int64
  }
  deriving (Show, Eq, Generic)

instance Hashable SelectSlicing

data DistinctAndOrderByExpr = ASorting
  { _sortAtNode :: (Postgres.OrderByExp, Maybe Postgres.DistinctExpr),
    _sortAtBase :: Maybe (Postgres.OrderByExp, Maybe Postgres.DistinctExpr)
  }
  deriving (Show, Eq, Generic)

instance Hashable DistinctAndOrderByExpr

-- | Sorting with -- Note [Optimizing queries using limit/offset])
data SelectSorting
  = NoSorting (Maybe Postgres.DistinctExpr)
  | Sorting DistinctAndOrderByExpr
  deriving (Show, Eq, Generic)

instance Hashable SelectSorting

data SortingAndSlicing = SortingAndSlicing
  { _sasSorting :: SelectSorting,
    _sasSlicing :: SelectSlicing
  }
  deriving (Show, Eq, Generic)

instance Hashable SortingAndSlicing

data SelectSource = SelectSource
  { _ssPrefix :: Postgres.Identifier,
    _ssFrom :: Postgres.FromItem,
    _ssWhere :: Postgres.BoolExp,
    _ssSortingAndSlicing :: SortingAndSlicing
  }
  deriving (Generic)

instance Hashable SelectSource

deriving instance Show SelectSource

deriving instance Eq SelectSource

noSortingAndSlicing :: SortingAndSlicing
noSortingAndSlicing =
  SortingAndSlicing (NoSorting Nothing) noSlicing

noSlicing :: SelectSlicing
noSlicing = SelectSlicing Nothing Nothing

orderByForJsonAgg :: SelectSource -> Maybe Postgres.OrderByExp
orderByForJsonAgg SelectSource {..} =
  case _sasSorting _ssSortingAndSlicing of
    NoSorting {} -> Nothing
    Sorting ASorting {..} -> Just $ fst _sortAtNode

data ApplySortingAndSlicing = ApplySortingAndSlicing
  { _applyAtBase :: (Maybe Postgres.OrderByExp, SelectSlicing, Maybe Postgres.DistinctExpr),
    _applyAtNode :: (Maybe Postgres.OrderByExp, SelectSlicing, Maybe Postgres.DistinctExpr)
  }

applySortingAndSlicing :: SortingAndSlicing -> ApplySortingAndSlicing
applySortingAndSlicing SortingAndSlicing {..} =
  case _sasSorting of
    NoSorting distinctExp -> withNoSorting distinctExp
    Sorting sorting -> withSoritng sorting
  where
    withNoSorting distinctExp =
      ApplySortingAndSlicing (Nothing, _sasSlicing, distinctExp) (Nothing, noSlicing, Nothing)
    withSoritng ASorting {..} =
      let (nodeOrderBy, nodeDistinctOn) = _sortAtNode
       in case _sortAtBase of
            Just (baseOrderBy, baseDistinctOn) ->
              ApplySortingAndSlicing (Just baseOrderBy, _sasSlicing, baseDistinctOn) (Just nodeOrderBy, noSlicing, nodeDistinctOn)
            Nothing ->
              ApplySortingAndSlicing (Nothing, noSlicing, Nothing) (Just nodeOrderBy, _sasSlicing, nodeDistinctOn)

data SelectNode = SelectNode
  { _snExtractors :: InsOrdHashMap Postgres.ColumnAlias Postgres.SQLExp,
    _snJoinTree :: JoinTree
  }
  deriving stock (Eq, Show)

instance Semigroup SelectNode where
  SelectNode lExtrs lJoinTree <> SelectNode rExtrs rJoinTree =
    SelectNode (lExtrs <> rExtrs) (lJoinTree <> rJoinTree)

data ObjectSelectSource = ObjectSelectSource
  { _ossPrefix :: Postgres.Identifier,
    _ossFrom :: Postgres.FromItem,
    _ossWhere :: Postgres.BoolExp
  }
  deriving (Show, Eq, Generic)

instance Hashable ObjectSelectSource

objectSelectSourceToSelectSource :: ObjectSelectSource -> SelectSource
objectSelectSourceToSelectSource ObjectSelectSource {..} =
  SelectSource _ossPrefix _ossFrom _ossWhere sortingAndSlicing
  where
    sortingAndSlicing = SortingAndSlicing noSorting limit1
    noSorting = NoSorting Nothing
    -- We specify 'LIMIT 1' here to mitigate misconfigured object relationships with an
    -- unexpected one-to-many/many-to-many relationship, instead of the expected one-to-one/many-to-one relationship.
    -- Because we can't detect this misconfiguration statically (it depends on the data),
    -- we force a single (or null) result instead by adding 'LIMIT 1'.
    -- Which result is returned might be non-deterministic (though only in misconfigured cases).
    -- Proper one-to-one/many-to-one object relationships should not be semantically affected by this.
    -- See: https://github.com/hasura/graphql-engine/issues/7936
    limit1 = SelectSlicing (Just 1) Nothing

data ObjectRelationSource = ObjectRelationSource
  { _orsRelationshipName :: RelName,
    _orsRelationMapping :: HashMap.HashMap Postgres.PGCol Postgres.PGCol,
    _orsSelectSource :: ObjectSelectSource,
    _orsNullable :: Nullable
  }
  deriving (Generic, Show)

instance Hashable ObjectRelationSource

deriving instance Eq ObjectRelationSource

data ArrayRelationSource = ArrayRelationSource
  { _arsAlias :: Postgres.TableAlias,
    _arsRelationMapping :: HashMap.HashMap Postgres.PGCol Postgres.PGCol,
    _arsSelectSource :: SelectSource
  }
  deriving (Generic, Show)

instance Hashable ArrayRelationSource

deriving instance Eq ArrayRelationSource

data MultiRowSelectNode = MultiRowSelectNode
  { _mrsnTopExtractors :: [Postgres.Extractor],
    _mrsnSelectNode :: SelectNode
  }
  deriving stock (Eq, Show)

instance Semigroup MultiRowSelectNode where
  MultiRowSelectNode lTopExtrs lSelNode <> MultiRowSelectNode rTopExtrs rSelNode =
    MultiRowSelectNode (lTopExtrs <> rTopExtrs) (lSelNode <> rSelNode)

data ComputedFieldTableSetSource = ComputedFieldTableSetSource
  { _cftssFieldName :: FieldName,
    _cftssSelectSource :: SelectSource
  }
  deriving (Generic)

instance Hashable ComputedFieldTableSetSource

deriving instance Show ComputedFieldTableSetSource

deriving instance Eq ComputedFieldTableSetSource

data ArrayConnectionSource = ArrayConnectionSource
  { _acsAlias :: Postgres.TableAlias,
    _acsRelationMapping :: HashMap.HashMap Postgres.PGCol Postgres.PGCol,
    _acsSplitFilter :: Maybe Postgres.BoolExp,
    _acsSlice :: Maybe ConnectionSlice,
    _acsSource :: SelectSource
  }
  deriving (Generic, Show)

deriving instance Eq ArrayConnectionSource

instance Hashable ArrayConnectionSource

----

data JoinTree = JoinTree
  { _jtObjectRelations :: HashMap.HashMap ObjectRelationSource SelectNode,
    _jtArrayRelations :: HashMap.HashMap ArrayRelationSource MultiRowSelectNode,
    _jtArrayConnections :: HashMap.HashMap ArrayConnectionSource MultiRowSelectNode,
    _jtComputedFieldTableSets :: HashMap.HashMap ComputedFieldTableSetSource MultiRowSelectNode
  }
  deriving stock (Eq, Show)

instance Semigroup JoinTree where
  JoinTree lObjs lArrs lArrConns lCfts <> JoinTree rObjs rArrs rArrConns rCfts =
    JoinTree
      (HashMap.unionWith (<>) lObjs rObjs)
      (HashMap.unionWith (<>) lArrs rArrs)
      (HashMap.unionWith (<>) lArrConns rArrConns)
      (HashMap.unionWith (<>) lCfts rCfts)

instance Monoid JoinTree where
  mempty = JoinTree mempty mempty mempty mempty

data PermissionLimitSubQuery
  = -- | Permission limit
    PLSQRequired Int
  | PLSQNotRequired
  deriving (Show, Eq)

type SimilarArrayFields = HashMap.HashMap FieldName [FieldName]

----

newtype CustomSQLCTEs = CustomSQLCTEs
  { getCustomSQLCTEs :: HashMap.HashMap Postgres.TableAlias (InterpolatedQuery Postgres.SQLExp)
  }
  deriving newtype (Eq, Show, Semigroup, Monoid)

----

data SelectWriter = SelectWriter
  { _swJoinTree :: JoinTree,
    _swCustomSQLCTEs :: CustomSQLCTEs
  }

instance Semigroup SelectWriter where
  (SelectWriter jtA cteA) <> (SelectWriter jtB cteB) =
    SelectWriter (jtA <> jtB) (cteA <> cteB)

instance Monoid SelectWriter where
  mempty = SelectWriter mempty mempty

----

newtype NativeQueryFreshIdStore = NativeQueryFreshIdStore {nqNextFreshId :: Int}
  deriving newtype (Eq, Show, Enum)

initialNativeQueryFreshIdStore :: NativeQueryFreshIdStore
initialNativeQueryFreshIdStore = NativeQueryFreshIdStore 0
