{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Conversion for moving top-level package items into modules
 -}

module Convert.NestPI (convert) where

import Control.Monad.State
import Control.Monad.Writer
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Convert.Traverse
import Language.SystemVerilog.AST

type PIs = Map.Map Identifier PackageItem
type Idents = Set.Set Identifier

convert :: [AST] -> [AST]
convert asts =
    map (filter (not . isPI) . nest) asts
    where
        nest :: AST -> AST
        nest curr =
            if next == curr
                then curr
                else nest next
            where
                next = evalState (traverseM curr) Map.empty
                traverseM = traverseDescriptionsM traverseDescriptionM
        isPI :: Description -> Bool
        isPI (PackageItem item) = piName item /= Nothing
        isPI _ = False

-- collects and nests in tasks and functions missing from modules
traverseDescriptionM :: Description -> State PIs Description
traverseDescriptionM (PackageItem item) = do
    () <- case piName item of
        Nothing -> return ()
        Just ident -> modify $ Map.insert ident item
    return $ PackageItem item
traverseDescriptionM (orig @ (Part extern kw lifetime name ports items)) = do
    tfs <- get
    let newItems = map MIPackageItem $ Map.elems $
            Map.restrictKeys tfs neededPIs
    return $ Part extern kw lifetime name ports (items ++ newItems)
    where
        existingPIs = execWriter $ collectModuleItemsM collectPIsM orig
        runner f = execWriter $ collectModuleItemsM f orig
        usedPIs = Set.unions $ map runner $
            [ collectStmtsM collectSubroutinesM
            , collectTypesM collectTypenamesM
            , collectExprsM $ collectNestedExprsM collectIdentsM
            ]
        neededPIs = Set.difference usedPIs existingPIs
traverseDescriptionM other = return other

-- writes down the names of package items
collectPIsM :: ModuleItem -> Writer Idents ()
collectPIsM (MIPackageItem item) =
    case piName item of
        Nothing -> return ()
        Just ident -> tell $ Set.singleton ident
collectPIsM _ = return ()

-- writes down the names of subroutine invocations
collectSubroutinesM :: Stmt -> Writer Idents ()
collectSubroutinesM (Subroutine f _) = tell $ Set.singleton f
collectSubroutinesM _ = return ()

-- writes down the names of function calls and identifiers
collectIdentsM :: Expr -> Writer Idents ()
collectIdentsM (Call    x _) = tell $ Set.singleton x
collectIdentsM (Ident   x  ) = tell $ Set.singleton x
collectIdentsM _ = return ()

-- writes down aliased typenames
collectTypenamesM :: Type -> Writer Idents ()
collectTypenamesM (Alias x _) = tell $ Set.singleton x
collectTypenamesM (Enum (Just t) _ _) = collectTypenamesM t
collectTypenamesM (Struct _ fields _) = do
    _ <- mapM collectTypenamesM $ map fst fields
    return ()
collectTypenamesM _ = return ()

-- returns the "name" of a package item, if it has one
piName :: PackageItem -> Maybe Identifier
piName (Function _ _ ident _ _) = Just ident
piName (Task     _   ident _ _) = Just ident
piName (Typedef    _ ident    ) = Just ident
piName (Decl (Variable _ _ ident _ _)) = Just ident
piName (Decl (Parameter  _ ident   _)) = Just ident
piName (Decl (Localparam _ ident   _)) = Just ident
piName (Import _ _) = Nothing
piName (Comment  _) = Nothing
