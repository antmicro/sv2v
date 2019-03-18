{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Source file loading and preprocessing
 -}
module Language.SystemVerilog.Parser.Preprocess
( loadFile
, PP (..)
) where

import Control.Monad.State
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import System.FilePath (replaceFileName)

import Language.SystemVerilog.Parser.Lex
import Language.SystemVerilog.Parser.Tokens


isNewline :: Token -> Bool
isNewline (Token t _ _) = t == Spe_Newline

unskippableDirectives :: [String]
unskippableDirectives = ["else", "elsif", "endif"]

preprocess :: [Token] -> (StateT PP IO) [Token]
preprocess tokens = pp tokens

data Cond
    = CurrentlyTrue
    | PreviouslyTrue
    | NeverTrue
    deriving (Eq, Show)

data PP = PP
    { ppEnv :: Map.Map String [Token]
    , ppCondStack :: [Cond]
    } deriving (Eq, Show)

pp :: [Token] -> (StateT PP IO) [Token]

pp [] = do
    condStack <- gets ppCondStack
    if null condStack
        then return []
        else error $ "have unfinished " ++ (show $ length condStack)
            ++ " conditional directive(s)"

pp (Token Spe_Directive str pos : tokens) = do
    let directive = tail str
    condStack <- gets ppCondStack
    env <- gets ppEnv
    if not (null condStack)
        && head condStack /= CurrentlyTrue
        && not (elem directive unskippableDirectives)
    then pp tokens
    else case directive of

        "default_nettype" -> do
            let str' = str ++ " " ++ (tokenString $ head tokens)
            let token' = Token Spe_Directive str' pos
            tokens' <- pp $ tail tokens
            return $ token' : tokens'

        "timescale" -> do
            -- timescale must appear alone on a line
            -- read tokens until the first (un-escaped) newline
            let (defn, rest) = break isNewline $ tokens
            let str' = str ++ " " ++ (intercalate " " $ map tokenString defn)
            let token' = Token Spe_Directive str' pos
            tokens' <- pp rest
            return $ token' : tokens'

        "include" -> do
            let file = init $ tail $ tokenString $ head tokens
            let Position basePath _ _ = pos
            let filePath = replaceFileName basePath file
            includedTokens <- loadFile filePath
            remainingTokens <- pp $ tail tokens
            return $ includedTokens ++ remainingTokens

        "ifdef" -> do
            let name = tokenString $ head tokens
            newCond <- return $
                if Map.member name env then CurrentlyTrue else NeverTrue
            modify $ \s -> s { ppCondStack = newCond : condStack }
            pp $ tail tokens
        "ifndef" -> do
            let name = tokenString $ head tokens
            newCond <- return $
                if Map.notMember name env then CurrentlyTrue else NeverTrue
            modify $ \s -> s { ppCondStack = newCond : condStack }
            pp $ tail tokens
        "else" -> do
            newCond <- return $
                if head condStack == NeverTrue then CurrentlyTrue else NeverTrue
            modify $ \s -> s { ppCondStack = newCond : tail condStack }
            pp tokens
        "elsif" -> do
            let name = tokenString $ head tokens
            let currCond = head condStack
            newCond <- return $
                if currCond /= NeverTrue then
                    PreviouslyTrue
                else if Map.member name env then
                    CurrentlyTrue
                else
                    NeverTrue
            modify $ \s -> s { ppCondStack = newCond : tail condStack }
            pp $ tail tokens
        "endif" -> do
            modify $ \s -> s { ppCondStack = tail condStack }
            pp tokens

        "define" -> do
            -- read tokens after the name until the first (un-escaped) newline
            let (defn, rest) = break isNewline $ tail tokens
            -- macro definitions can contain macros, but no conditionals, so we
            -- temporarily drop the condition stack while we preprocess it
            modify' $ \s -> s { ppCondStack = [] }
            defn' <- pp defn
            modify' $ \s -> s { ppCondStack = condStack }
            let env' = Map.insert (tokenString $ head tokens) defn' env
            modify $ \s -> s { ppEnv = env' }
            pp rest -- drop the macro, process the rest of the tokens
        "undef" -> do
            let name = tokenString $ head tokens
            modify $ \s -> s { ppEnv = Map.delete name env }
            pp $ tail tokens
        "undefineall" -> do
            modify $ \s -> s { ppEnv = Map.empty }
            pp tokens

        _ -> do
            case Map.lookup directive env of
                Nothing -> do
                    error $ "Undefined macro: " ++ directive ++ " at " ++ (show pos)
                Just replacement -> do
                    -- TODO: How should we track the position of tokens that are
                    -- substituted in? Using only one position or the other
                    -- doesn't tell the full story.
                    tokens' <- pp tokens
                    return $ replacement ++ tokens'

pp (Token Spe_Newline _ _ : tokens) = pp tokens
pp (Token Spe_Comment _ _ : tokens) = pp tokens

pp (Token Spe_CommentBegin _ _ : tokens) =
    pp $ tail $ dropWhile (not . isEnd) tokens
    where isEnd (Token t _ _ ) = t == Spe_CommentEnd

pp (token : tokens) = do
    condStack <- gets ppCondStack
    tokens' <- pp tokens
    if not (null condStack) && head condStack /= CurrentlyTrue
        then return tokens'
        else return $ token : tokens'

-- loads, lexes, and preprocesses the file at the given path
loadFile :: FilePath -> (StateT PP IO) [Token]
loadFile file = do
    content <- lift $ readFile file
    preprocess $
        map relocate $
        alexScanTokens $
        content
    where
        relocate :: Token -> Token
        relocate (Token t s (Position _ l c)) = Token t s $ Position file l c
