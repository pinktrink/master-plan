{-|
Module      : MasterPlan.Backend.Graph
Description : a backend that renders to PNG diagram
Copyright   : (c) Rodrigo Setti, 2017
License     : MIT
Maintainer  : rodrigosetti@gmail.com
Stability   : experimental
Portability : POSIX
-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TupleSections             #-}
module MasterPlan.Backend.Graph (render, RenderOptions(..)) where

import           MasterPlan.Data
import           Diagrams.Prelude hiding (render)
import           Diagrams.Backend.Rasterific
import qualified Data.Map as M
import qualified Data.List.NonEmpty as NE
import           Data.Maybe (fromMaybe, catMaybes)
import           Text.Printf (printf)
import Data.List (intersperse)
--import Diagrams.TwoD.Text (Text)

-- text :: (TypeableFloat n, Renderable (Text n) b) => String -> QDiagram b V2 n Any
-- text = texterific

-- * Types

-- |Generic tree
data Tree t n = Tree t n (NE.NonEmpty (Tree t n)) | Leaf n

data NodeType = SumNode | ProductNode | SequenceNode

-- |Data type used by the tree
data Node = Node (Maybe ProjectKey)
                 (Maybe ProjectProperties)
                 Cost
                 Trust
                 Progress
          | NodeRef ProjectKey

type RenderModel = Tree NodeType Node

-- |Translates a ProjectSystem into a Tree Node
toRenderModel :: ProjectSystem -> ProjectKey -> Maybe RenderModel
toRenderModel sys rootK = bindingToRM rootK <$> M.lookup rootK (bindings sys)
  where
    bindingToRM :: ProjectKey -> ProjectBinding -> RenderModel
    bindingToRM key (ExpressionProj prop p) = projToRM p (Just key) (Just prop)
    bindingToRM key (TaskProj prop c t p) = Leaf $ Node (Just key)
                                                        (Just prop)
                                                        c t p
    bindingToRM key (UnconsolidatedProj prop) = Leaf $ Node (Just key)
                                                            (Just prop)
                                                            defaultCost
                                                            defaultTrust
                                                            defaultProgress
    mkNode :: (Node -> NE.NonEmpty RenderModel -> RenderModel) -> Project -> NE.NonEmpty Project -> Maybe ProjectKey -> Maybe ProjectProperties -> RenderModel
    mkNode f p ps key prop = f (Node key prop
                                     (cost sys p)
                                     (trust sys p)
                                     (progress sys p))
                               $ NE.map (\p' -> projToRM p' Nothing Nothing) ps

    projToRM :: Project -> Maybe ProjectKey -> Maybe ProjectProperties -> RenderModel
    projToRM p@(SumProj ps) = mkNode (Tree SumNode) p ps
    projToRM p@(SequenceProj ps) = mkNode (Tree SequenceNode) p ps
    projToRM p@(ProductProj ps) = mkNode (Tree ProductNode) p ps
    projToRM (RefProj n) = -- TODO: avoid repeating
      \k p -> case M.lookup n $ bindings sys of
          Nothing -> Leaf $ Node k p 1 1 0
          Just b -> bindingToRM n b

-- |how many children
treeSize :: Num a => Tree t n -> a
treeSize (Tree _ _ ts) = sum $ NE.map treeSize ts
treeSize _ = 1

data RenderOptions = RenderOptions { colorByProgress :: Bool
                                   , renderWidth :: Integer
                                   , renderHeight :: Integer
                                   , rootKey :: ProjectKey
                                   , whitelistedProps :: [ProjProperty] }
                          deriving (Eq, Show)

-- | The main rendering function
render ∷ FilePath -> RenderOptions-> ProjectSystem → IO ()
render fp (RenderOptions colorByP w h rootK props) sys =
  let noRootEroor = text $ "no project named \"" ++ rootK ++ "\" found."
      dia :: QDiagram B V2 Double Any
      dia = fromMaybe noRootEroor $ renderTree colorByP props <$> toRenderModel sys rootK
  in renderRasterific fp (dims $ V2 (fromInteger w) (fromInteger h)) $ pad 1.05 $ centerXY dia

renderTree :: Bool -> [ProjProperty] -> RenderModel -> QDiagram B V2 Double Any
renderTree colorByP props (Leaf n) = alignL $ renderNode colorByP props n
renderTree colorByP props t@(Tree ty n ts) =
    (strut (V2 0 siz) <> alignL (centerY $ renderNode colorByP props n))
    |||  (translateX 2 typeSymbol # withEnvelope (mempty :: D V2 Double) <> hrule 4)
    |||  centerY (headBar === treeBar (map ((* 6) . treeSize) ts'))
    |||  centerY (vcat $ map renderSubTree ts')
  where
    siz = 12 * treeSize t
    renderSubTree subtree = hrule 4 ||| renderTree colorByP props subtree
    ts' = NE.toList ts

    headBar = strut $ V2 0 $ treeSize (NE.head ts) * 6

    treeBar :: [Double] -> QDiagram B V2 Double Any
    treeBar (s1:s2:ss) = vrule s1 === vrule s2 === treeBar (s2:ss)
    treeBar [s1] = strut $ V2 0 s1
    treeBar _ = mempty

    typeSymbol = case ty of
                    SumNode -> text "+" <> circle 1 # fc white # lw 1
                    ProductNode -> text "x" <> circle 1 # fc white # lw 1
                    SequenceNode -> text ">" <> circle 1 # fc white # lw 1

renderNode :: Bool -> [ProjProperty] -> Node -> QDiagram B V2 Double Any
renderNode _        _     (NodeRef n) = pad 1.1 $ roundedRect 30 2 0.5 <> text n
renderNode colorByP props (Node key prop c t p) =
   centerY nodeDia # withEnvelope (rect 30 12 :: D V2 Double)
  where
    nodeDia =
      let hSizeAndSections = catMaybes [ (,2) <$> headerSection
                                       , (,6) <$> descriptionSection
                                       , (,2) <$> urlSection
                                       , (,2) <$> bottomSection]
          sections = map (\s -> strut (V2 0 $ snd s) <> fst s) hSizeAndSections
          outerRect = rect 30 $ sum $ map snd hSizeAndSections
          sectionsWithSep = vcat (intersperse (hrule 30 # dashingN [0.005, 0.005] 0 # lw 1) sections)
      in outerRect # fcColor `beneath` centerY sectionsWithSep

    givenProp :: ProjProperty -> Maybe a -> Maybe a
    givenProp pro x = if pro `elem` props then x else Nothing

    headerSection = case (progressHeader, titleHeader, costHeader) of
                        (Nothing, Nothing, Nothing) -> Nothing
                        (x, y, z) -> Just $ centerX $ fromMaybe mempty x
                                                 |||  fromMaybe mempty y
                                                 |||  fromMaybe mempty z
    progressHeader = givenProp PProgress $ Just $ strut (V2 5 0) <> displayProgress p
    titleHeader = givenProp PTitle $ ((strut (V2 20 0) <>) . bold . text . title) <$> prop
    costHeader = givenProp PCost $ Just $ strut (V2 5 0) <> displayCost c

    descriptionSection, urlSection, bottomSection :: Maybe (QDiagram B V2 Double Any)
    descriptionSection = givenProp PDescription $ prop >>= description >>= (pure . text) -- TODO line breaks
    urlSection = givenProp PUrl $ prop >>= url >>= (pure . text) -- TODO ellipsis

    bottomSection = case (trustSubSection, ownerSubSection) of
                      (Nothing, Nothing) -> Nothing
                      (ma, mb) -> let st = strut (V2 15 0)
                                   in Just $ centerX $ (st <> fromMaybe mempty ma) |||
                                                       (st <> fromMaybe mempty mb)

    ownerSubSection = prop >>= owner >>= (pure . text)
    trustSubSection = case t of
                          _  | PTrust `notElem` props -> Nothing
                          t' | t' == 1 -> Nothing
                          t' | t' == 0 -> Just $ text "impossible"
                          _ -> Just $ text ("trust = " ++ percentageText t)

    displayCost c'
      | c' == 0   = mempty
      | otherwise = text $ "(" ++ printf "%.1f" c' ++ ")"
    displayProgress p'
      | p' == 1 = text "done"
      | p' == 0 = mempty
      | otherwise = text $ percentageText p'

    fcColor =
      fc $ if colorByP then
                (if p <= 0.25 then pink else if p == 1 then lightgreen else lightyellow)
           else white

    percentageText pct = show ((round $ pct * 100) :: Integer) ++ "%"
