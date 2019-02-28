{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Conversion for flattening multi-dimensional packed arrays
 -
 - This removes one dimension per identifier at a time. This works fine because
 - the conversions are repeatedly applied.
 -
 - TODO: This assumes that the first range index is the upper bound. We could
 - probably get arround this with some cleverness in the generate block. I don't
 - think it's urgent to have support for "backwards" ragnes.
 -}

module Convert.PackedArray (convert) where

import Control.Monad.State
import Data.List (partition)
import qualified Data.Map.Strict as Map

import Convert.Traverse
import Language.SystemVerilog.AST

type DirMap = Map.Map Identifier Direction
type DimMap = Map.Map Identifier (Type, Range)

convert :: AST -> AST
convert = traverseDescriptions convertDescription

convertDescription :: Description -> Description
convertDescription description =
    hoistPortDecls $
    traverseModuleItems (flattenModuleItem info . convertModuleItem dimMap') description
    where
        info = execState
            (collectModuleItemsM collectDecl description)
            (Map.empty, Map.empty)
        dimMap' = Map.restrictKeys (fst info) (Map.keysSet $ snd info)

-- collects port direction and packed-array dimension info into the state
collectDecl :: ModuleItem -> State (DimMap, DirMap) ()
collectDecl (MIDecl (Variable dir t ident _ _)) = do
    let (tf, rs) = typeDims t
    if length rs > 1
        then modify $ \(m, r) -> (Map.insert ident (tf $ tail rs, head rs) m, r)
        else return ()
    if dir /= Local
        then modify $ \(m, r) -> (m, Map.insert ident dir r)
        else return ()
collectDecl _ = return ()

-- VCS doesn't like port declarations inside of `generate` blocks, so we hoist
-- them out with this function. This obviously isn't ideal, but it's a
-- relatively straightforward transformation, and testing in VCS is important.
hoistPortDecls :: Description -> Description
hoistPortDecls (Module name ports items) =
    Module name ports (concat $ map explode items)
    where
        explode :: ModuleItem -> [ModuleItem]
        explode (Generate genItems) =
            portDecls ++ [Generate rest]
            where
                (wrappedPortDecls, rest) = partition isPortDecl genItems
                portDecls = map (\(GenModuleItem item) -> item) wrappedPortDecls
                isPortDecl :: GenItem -> Bool
                isPortDecl (GenModuleItem (MIDecl (Variable dir _ _ _ _))) =
                    dir /= Local
                isPortDecl _ = False
        explode other = [other]
hoistPortDecls other = other

-- rewrite a module item if it contains a declaration to flatten
flattenModuleItem :: (DimMap, DirMap) -> ModuleItem -> ModuleItem
flattenModuleItem (dimMap, dirMap) (orig @ (MIDecl (Variable dir t ident a me))) =
    -- if it doesn't need any mapping
    if Map.notMember ident dimMap then
        -- Skip!
        orig
    -- if it's not a port
    else if Map.notMember ident dirMap then
        -- move the packed dimension to the unpacked side
        MIDecl $ Variable dir (tf $ tail rs) ident (a ++ [head rs]) me
    -- if it is a port, but it's not the typed declaration
    else if typeIsImplicit t then
        -- flatten the ranges
        newDecl -- see below
    -- if it is a port, and it is the typed declaration of that por
    else
        -- do the fancy flatten-unflatten mapping
        Generate $ (GenModuleItem newDecl) : genItems
    where
        (tf, rs) = typeDims t
        t' = tf $ flattenRanges rs
        flipGen = Map.lookup ident dirMap == Just Input
        genItems = unflattener flipGen ident (dimMap Map.! ident)
        newDecl = MIDecl $ Variable dir t' ident a me
        typeIsImplicit :: Type -> Bool
        typeIsImplicit (Implicit _) = True
        typeIsImplicit _ = False
flattenModuleItem _ other = other

-- produces a generate block for creating a local unflattened copy of the given
-- port-exposed flattened array
unflattener :: Bool -> Identifier -> (Type, Range) -> [GenItem]
unflattener shouldFlip arr (t, (majorHi, majorLo)) =
        [ GenModuleItem $ Comment $ "sv2v packed-array-flatten unflattener for " ++ arr
        , GenModuleItem $ MIDecl $ Variable Local t arrUnflat [(majorHi, majorLo)] Nothing
        , GenModuleItem $ Genvar index
        , GenModuleItem $ MIDecl $ Variable Local IntegerT (arrUnflat ++ "_repeater_index") [] Nothing
        , GenFor
            (index, majorLo)
            (BinOp Le (Ident index) majorHi)
            (index, BinOp Add (Ident index) (Number "1"))
            (prefix "unflatten")
            [ localparam startBit
                (simplify $ BinOp Add majorLo
                    (BinOp Mul (Ident index) size))
            , GenModuleItem $ (uncurry Assign) $
                if shouldFlip
                    then (LHSBit arrUnflat $ Ident index, IdentRange arr origRange)
                    else (LHSRange arr origRange, IdentBit arrUnflat $ Ident index)
            ]
        ]
    where
        startBit = prefix "_tmp_start"
        arrUnflat = prefix arr
        index = prefix "_tmp_index"
        (minorHi, minorLo) = head $ snd $ typeDims t
        size = simplify $ BinOp Add (BinOp Sub minorHi minorLo) (Number "1")
        localparam :: Identifier -> Expr -> GenItem
        localparam x v = GenModuleItem $ MIDecl $ Localparam (Implicit []) x v
        origRange = ( (BinOp Add (Ident startBit)
                        (BinOp Sub size (Number "1")))
                    , Ident startBit )

-- basic expression simplfication utility to help us generate nicer code in the
-- common case of ranges like `[FOO-1:0]`
simplify :: Expr -> Expr
simplify (BinOp op e1 e2) =
    case (op, e1', e2') of
        (Add, Number "0", e) -> e
        (Add, e, Number "0") -> e
        (Sub, e, Number "0") -> e
        (Add, BinOp Sub e (Number "1"), Number "1") -> e
        (Add, e, BinOp Sub (Number "0") (Number "1")) -> BinOp Sub e (Number "1")
        _ -> BinOp op e1' e2'
    where
        e1' = simplify e1
        e2' = simplify e2
simplify other = other

-- prefix a string with a namespace of sorts
prefix :: Identifier -> Identifier
prefix ident = "_sv2v_" ++ ident


-- TODO FIXME XXX: There is a huge opportunity here to simplify the code after
-- this point in the module. Each of these mappings have a bit of their own
-- quirks. They cover all LHSs, expressions, and statements, at every level.


rewriteRange :: DimMap -> Range -> Range
rewriteRange dimMap (a, b) = (r a, r b)
    where r = rewriteExpr dimMap

rewriteIdentifier :: DimMap -> Identifier -> Identifier
rewriteIdentifier dimMap x =
    if Map.member x dimMap
        then prefix x
        else x

rewriteExpr :: DimMap -> Expr -> Expr
rewriteExpr dimMap = rewriteExpr'
    where
        ri :: Identifier -> Identifier
        ri = rewriteIdentifier dimMap
        re = rewriteExpr'
        rewriteExpr' :: Expr -> Expr
        rewriteExpr' (String     s) = String    s
        rewriteExpr' (Number     s) = Number    s
        rewriteExpr' (ConstBool  b) = ConstBool b
        rewriteExpr' (Ident      i  ) = Ident      (ri i)
        rewriteExpr' (IdentRange i (r @ (s, e))) =
            case Map.lookup i dimMap of
                Nothing -> IdentRange (ri i) (rewriteRange dimMap r)
                Just (t, _) ->
                    IdentRange i (simplify s', simplify e')
                    where
                        (a, b) = head $ snd $ typeDims t
                        size = BinOp Add (BinOp Sub a b) (Number "1")
                        s' = BinOp Sub (BinOp Mul size (BinOp Add s (Number "1"))) (Number "1")
                        e' = BinOp Mul size e
        rewriteExpr' (IdentBit   i e) = IdentBit   (ri i) (re e)
        rewriteExpr' (Repeat     e l) = Repeat (re e) (map re l)
        rewriteExpr' (Concat     l  ) = Concat (map re l)
        rewriteExpr' (Call       f l) = Call f (map re l)
        rewriteExpr' (UniOp      o e) = UniOp o (re e)
        rewriteExpr' (BinOp      o e1 e2) = BinOp o (re e1) (re e2)
        rewriteExpr' (Mux        e1 e2 e3) = Mux (re e1) (re e2) (re e3)
        rewriteExpr' (Bit        e n) = Bit (re e) n
        rewriteExpr' (Cast       t e) = Cast t (re e)

-- combines (flattens) the bottom two ranges in the given list of ranges
flattenRanges :: [Range] -> [Range]
flattenRanges rs =
    if length rs >= 2
        then rs'
        else error $ "flattenRanges on too small list: " ++ (show rs)
    where
        (s1, e1) = head rs
        (s2, e2) = head $ tail rs
        size1 = BinOp Add (BinOp Sub s1 e1) (Number "1")
        size2 = BinOp Add (BinOp Sub s2 e2) (Number "1")
        upper = BinOp Add (BinOp Mul size1 size2) (BinOp Sub e1 (Number "1"))
        r' = (simplify upper, e1)
        rs' = (tail $ tail rs) ++ [r']

rewriteLHS :: DimMap -> LHS -> LHS
rewriteLHS dimMap (LHS      x  ) = LHS      (rewriteIdentifier dimMap x)
rewriteLHS dimMap (LHSBit   x e) = LHSBit   (rewriteIdentifier dimMap x) (rewriteExpr  dimMap e)
rewriteLHS dimMap (LHSRange x r) = LHSRange (rewriteIdentifier dimMap x) (rewriteRange dimMap r)
rewriteLHS dimMap (LHSConcat ls) = LHSConcat $ map (rewriteLHS dimMap) ls

rewriteStmt :: DimMap -> Stmt -> Stmt
rewriteStmt dimMap orig = rs orig
    where
        rs :: Stmt -> Stmt
        rs (Block decls stmts) = Block decls (map rs stmts)
        rs (Case kw e cases def) = Case kw e' cases' def'
            where
                re :: Expr -> Expr
                re = rewriteExpr dimMap
                rc :: Case -> Case
                rc (exprs, stmt) = (map re exprs, rs stmt)
                e' = re e
                cases' = map rc cases
                def' = fmap rs def
        rs (AsgnBlk lhs expr) = convertAssignment AsgnBlk lhs expr
        rs (Asgn    lhs expr) = convertAssignment Asgn    lhs expr
        rs (For (x1, e1) cc (x2, e2) stmt) = For (x1, e1') cc' (x2, e2') (rs stmt)
            where
                e1' = rewriteExpr dimMap e1
                e2' = rewriteExpr dimMap e2
                cc' = rewriteExpr dimMap cc
        rs (If cc s1 s2) = If (rewriteExpr dimMap cc) (rs s1) (rs s2)
        rs (Timing sense stmt) = Timing sense (rs stmt)
        rs (Null) = Null
        convertAssignment :: (LHS -> Expr -> Stmt) -> LHS -> Expr -> Stmt
        convertAssignment constructor (lhs @ (LHS ident)) (expr @ (Repeat _ exprs)) =
            case Map.lookup ident dimMap of
                Nothing -> constructor (rewriteLHS dimMap lhs) (rewriteExpr dimMap expr)
                Just (_, (a, b)) ->
                    For inir chkr incr assign
                    where
                        index = prefix $ ident ++ "_repeater_index"
                        assign = constructor
                            (LHSBit (prefix ident) (Ident index))
                            (Concat exprs)
                        inir = (index, b)
                        chkr = BinOp Le (Ident index) a
                        incr = (index, BinOp Add (Ident index) (Number "1"))
        convertAssignment constructor lhs expr =
            constructor (rewriteLHS dimMap lhs) (rewriteExpr dimMap expr)

convertModuleItem :: DimMap -> ModuleItem -> ModuleItem
convertModuleItem dimMap (MIDecl (Variable d t x a me)) =
    MIDecl $ Variable d t  x a' me'
    where
        a' = map (rewriteRange dimMap) a
        me' = fmap (rewriteExpr dimMap) me
convertModuleItem dimMap (Assign lhs expr) =
    Assign (rewriteLHS dimMap lhs) (rewriteExpr dimMap expr)
convertModuleItem dimMap (AlwaysC kw stmt) =
    AlwaysC kw (rewriteStmt dimMap stmt)
convertModuleItem dimMap (Function ret f decls stmt) =
    Function ret f decls (rewriteStmt dimMap stmt)
convertModuleItem dimMap (Instance m params x ml) =
    Instance m params x $ fmap (map convertPortBinding) ml
    where
        convertPortBinding :: PortBinding -> PortBinding
        convertPortBinding (p, Nothing) = (p, Nothing)
        convertPortBinding (p, Just  e) = (p, Just $ rewriteExpr dimMap e)
convertModuleItem _ (Comment  x) = Comment  x
convertModuleItem _ (Genvar   x) = Genvar   x
convertModuleItem _ (MIDecl   x) = MIDecl   x
convertModuleItem _ (Generate x) = Generate x