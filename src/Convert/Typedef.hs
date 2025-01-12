{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Conversion for `typedef`
 -
 - Aliased types can appear in all data declarations, including modules, blocks,
 - and function parameters. They are also found in type cast expressions.
 -}

module Convert.Typedef (convert) where

import Control.Monad.Writer
import qualified Data.Map as Map

import Convert.Traverse
import Language.SystemVerilog.AST

type Types = Map.Map Identifier Type

convert :: [AST] -> [AST]
convert =
    traverseFiles
        (collectDescriptionsM getTypedef)
        (\a -> traverseDescriptions $ removeTypedef . convertDescription a)
    where
        getTypedef :: Description -> Writer Types ()
        getTypedef (PackageItem (Typedef a b)) = tell $ Map.singleton b a
        getTypedef _ = return ()
        removeTypedef :: Description -> Description
        removeTypedef (PackageItem (Typedef _ x)) =
            PackageItem $ Comment $ "removed typedef: " ++ x
        removeTypedef other = other

convertDescription :: Types -> Description -> Description
convertDescription globalTypes description =
    traverseModuleItems removeTypedef $
    traverseModuleItems (traverseExprs $ traverseNestedExprs $ convertExpr) $
    traverseModuleItems (traverseTypes $ resolveType types) $
    description
    where
        types = Map.union globalTypes $
            execWriter $ collectModuleItemsM getTypedef description
        getTypedef :: ModuleItem -> Writer Types ()
        getTypedef (MIPackageItem (Typedef a b)) = tell $ Map.singleton b a
        getTypedef _ = return ()
        removeTypedef :: ModuleItem -> ModuleItem
        removeTypedef (MIPackageItem (Typedef _ x)) =
            MIPackageItem $ Comment $ "removed typedef: " ++ x
        removeTypedef other = other
        convertExpr :: Expr -> Expr
        convertExpr (Bits (Right (Ident x))) =
            if Map.member x types
                then Bits $ Left $ resolveType types (Alias Nothing x [])
                else Bits $ Right $ Ident x
        convertExpr other = other

resolveItem :: Types -> (Type, Identifier) -> (Type, Identifier)
resolveItem types (t, x) = (resolveType types t, x)

resolveType :: Types -> Type -> Type
resolveType _ (Net           kw    rs) = Net           kw    rs
resolveType _ (Implicit         sg rs) = Implicit         sg rs
resolveType _ (IntegerVector kw sg rs) = IntegerVector kw sg rs
resolveType _ (IntegerAtom   kw sg   ) = IntegerAtom   kw sg
resolveType _ (NonInteger    kw      ) = NonInteger    kw
resolveType _ (InterfaceT     x my rs) = InterfaceT     x my rs
resolveType _ (Enum Nothing   vals rs) = Enum Nothing   vals rs
resolveType _ (Alias (Just ps)  st rs) = Alias (Just ps)  st rs
resolveType types (Enum (Just t) vals rs) = Enum (Just $ resolveType types t) vals rs
resolveType types (Struct p items rs) = Struct p (map (resolveItem types) items) rs
resolveType types (Union  p items rs) = Union  p (map (resolveItem types) items) rs
resolveType types (Alias Nothing st rs1) =
    if Map.notMember st types
    then InterfaceT st Nothing rs1
    else case resolveType types $ types Map.! st of
        (Net           kw    rs2) -> Net           kw    $ rs1 ++ rs2
        (Implicit         sg rs2) -> Implicit         sg $ rs1 ++ rs2
        (IntegerVector kw sg rs2) -> IntegerVector kw sg $ rs1 ++ rs2
        (Enum            t v rs2) -> Enum            t v $ rs1 ++ rs2
        (Struct          p l rs2) -> Struct          p l $ rs1 ++ rs2
        (Union           p l rs2) -> Union           p l $ rs1 ++ rs2
        (InterfaceT     x my rs2) -> InterfaceT     x my $ rs1 ++ rs2
        (IntegerAtom   kw _ ) -> error $ "resolveType encountered packed `" ++ (show kw) ++ "` on " ++ st
        (NonInteger    kw   ) -> error $ "resolveType encountered packed `" ++ (show kw) ++ "` on " ++ st
        (Alias  _ _ _) -> error $ "resolveType invariant failed on " ++ st
