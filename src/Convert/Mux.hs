{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Elaboration of ternary expressions where the condition references a
 - localparam.
 -
 - Our conversions generate a lot of ternary expressions. This conversion
 - attempts to make the code output a bit cleaner. Note that we can only do this
 - simplification on localparams because parameters can be overridden at
 - instantiation.
 -
 - This conversion applies the heuristic that it will only make substitutions
 - into a ternary condition if making substitutions immediately enables the
 - expression to be simplified further.
 -}

module Convert.Mux (convert) where

import Control.Monad.State
import qualified Data.Map.Strict as Map

import Convert.Traverse
import Language.SystemVerilog.AST

type Info = Map.Map Identifier Expr

convert :: [AST] -> [AST]
convert = map $ traverseDescriptions convertDescription

convertDescription :: Description -> Description
convertDescription =
    scopedConversion traverseDeclM traverseModuleItemM traverseStmtM Map.empty

traverseDeclM :: Decl -> State Info Decl
traverseDeclM decl = do
    case decl of
        Localparam _ x e -> modify $ Map.insert x e
        _ -> return ()
    return decl

traverseModuleItemM :: ModuleItem -> State Info ModuleItem
traverseModuleItemM item = traverseExprsM traverseExprM item

traverseStmtM :: Stmt -> State Info Stmt
traverseStmtM stmt = traverseStmtExprsM traverseExprM stmt

traverseExprM :: Expr -> State Info Expr
traverseExprM = traverseNestedExprsM $ stately convertExpr

convertExpr :: Info -> Expr -> Expr
convertExpr info (Mux cc aa bb) =
    if before == after
        then Mux cc aa bb
        else simplify $ Mux after aa bb
    where
        before = traverseNestedExprs substitute (simplify cc)
        after = simplify before
        substitute :: Expr -> Expr
        substitute (Ident x) =
            case Map.lookup x info of
                Nothing -> Ident x
                Just e-> e
        substitute other = other
convertExpr _ other = other

