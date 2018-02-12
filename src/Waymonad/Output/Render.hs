module Waymonad.Output.Render
where

import Control.Monad (forM_, when, void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, readIORef)
import Foreign.Ptr (Ptr)

import Graphics.Wayland.Resource (resourceDestroy)
import Graphics.Wayland.Server
    ( outputTransformFlipped_180, callbackDone)

import Graphics.Pixman
import Graphics.Wayland.WlRoots.Box (WlrBox (..), Point (..), boxTransform, scaleBox)
import Graphics.Wayland.WlRoots.Output
    ( WlrOutput, getOutputDamage , isOutputEnabled, getOutputNeedsSwap
    , getHeight, getWidth, invertOutputTransform, getOutputTransform
    , outputTransformedResolution, composeOutputTransform, getTransMatrix
      , swapOutputBuffers, getOutputScale, makeOutputCurrent
    )
import Graphics.Wayland.WlRoots.Render
    ( Renderer, rendererScissor, rendererClear, renderWithMatrix, isTextureValid
    , doRender
    )
import Graphics.Wayland.WlRoots.Render.Color (Color (..))
import Graphics.Wayland.WlRoots.Render.Matrix
    ( matrixMul, matrixScale, matrixTranslate, withMatrix)
import Graphics.Wayland.WlRoots.Surface
    ( WlrSurface, subSurfaceGetSurface, surfaceGetSubs, subSurfaceGetBox
    , surfaceGetCallbacks, getCurrentState, withSurfaceMatrix
    , callbackGetCallback , callbackGetResource, surfaceGetScale
    , surfaceGetTexture
    )

import Waymonad (getState, makeCallback , unliftWay)
import Waymonad.Types
    ( Way, Output (..), SSDPrio
    , Compositor (..)
    , WayBindingState (..)
    )
import Waymonad.Types.Core (View)
import Waymonad.View
    ( viewHasCSD, viewGetLocal, getViewSurface, renderViewAdditional
    , viewGetScale
    )
import Waymonad.Utility.SSD (renderDeco, getDecoBox)
import Waymonad.Utility.Base (doJust)
import Waymonad.ViewSet (WSTag)

renderOn :: Ptr WlrOutput -> Ptr Renderer -> (Int -> Way vs ws ()) -> Way vs ws ()
renderOn output rend act = doJust (liftIO $ makeOutputCurrent output) $ \age -> do
    liftIO . doRender rend output =<< unliftWay (act age)

    void . liftIO $ swapOutputBuffers output Nothing

outputHandleSurface :: Compositor -> Double -> Ptr WlrOutput -> PixmanRegion32 -> Ptr WlrSurface -> Float -> WlrBox -> IO ()
outputHandleSurface comp secs output damage surface scaleFactor box = do
    outputScale <- getOutputScale output
    surfScale <- fromIntegral <$> surfaceGetScale surface
    let localScale = (outputScale / surfScale) * scaleFactor
    texture <- surfaceGetTexture surface
    isValid <- isTextureValid texture
    when isValid $ withMatrix $ \trans -> withMatrix $ \scale -> withMatrix $ \final -> do
            let x = fromIntegral (boxX box) * outputScale
                y = fromIntegral (boxY box) * outputScale

            matrixTranslate trans x y 0
            matrixScale scale localScale localScale 1
            matrixMul trans scale final
            withSurfaceMatrix surface (getTransMatrix output) final $ \mat ->
                withRegion $ \region -> do
                    resetRegion region . Just $ scaleBox box outputScale
                    pixmanRegionIntersect region damage
                    boxes <- pixmanRegionBoxes region
                    forM_ boxes $ \pbox -> do
                        scissorOutput (compRenderer comp) output $ boxToWlrBox pbox
                        renderWithMatrix (compRenderer comp) texture mat

            callbacks <- surfaceGetCallbacks =<< getCurrentState surface
            forM_ callbacks $ \callback -> do
                cb <- callbackGetCallback callback
                callbackDone cb (floor $ secs * 1000)
                res <- callbackGetResource callback
                resourceDestroy res

            subs <- surfaceGetSubs surface
            forM_ subs $ \sub -> do
                sbox <- subSurfaceGetBox sub
                subsurf <- subSurfaceGetSurface sub
                outputHandleSurface
                    comp
                    secs
                    output
                    damage
                    subsurf
                    scaleFactor
                    sbox{ boxX = floor (fromIntegral (boxX sbox) * scaleFactor) + boxX box
                        , boxY = floor (fromIntegral (boxY sbox) * scaleFactor) + boxY box
                        , boxWidth = floor $ fromIntegral (boxWidth sbox) * scaleFactor
                        , boxHeight = floor $ fromIntegral (boxHeight sbox) * scaleFactor
                        }

outputHandleView :: Compositor -> Double -> Ptr WlrOutput -> PixmanRegion32 -> (View, SSDPrio, WlrBox) -> Way vs ws (IO ())
outputHandleView comp secs output d (view, prio, obox) = doJust (getViewSurface view) $ \surface -> do
    hasCSD <- viewHasCSD view
    let box = getDecoBox hasCSD prio obox
    scale <- liftIO $ viewGetScale view
    local <- liftIO $ viewGetLocal view
    let lBox = box { boxX = boxX box + boxX local, boxY = boxY box + boxY local}
    -- TODO: Limit to damaged areas
    liftIO $ scissorOutput (compRenderer comp) output obox
    renderDeco hasCSD prio output obox box
    liftIO $ outputHandleSurface comp secs output d surface scale lBox
    pure $ renderViewAdditional (\v b ->
        void $ outputHandleSurface
            comp
            secs
            output
            d
            v
            scale
            b   { boxX = floor (fromIntegral (boxX b) * scale) + boxX lBox
                , boxY = floor (fromIntegral (boxY b) * scale) + boxY lBox
                , boxWidth = floor $ fromIntegral (boxWidth b) * scale
                , boxHeight = floor $ fromIntegral (boxHeight b) * scale
                }
        )
        view

handleLayers :: Compositor -> Double -> Ptr WlrOutput
             -> [IORef [(View, SSDPrio, WlrBox)]] 
             -> PixmanRegion32 -> Way vs ws ()
handleLayers _ _ _ [] _ = pure ()
handleLayers comp secs output (l:ls) d = do
    handleLayers comp secs output ls d
    views <- liftIO $ readIORef l
    overs <- mapM (outputHandleView comp secs output d) views
    liftIO $ sequence_ overs

scissorOutput :: Ptr Renderer -> Ptr WlrOutput -> WlrBox -> IO ()
scissorOutput rend output box = do
    Point w h <- outputTransformedResolution output
    trans <- getOutputTransform output
    let transform = composeOutputTransform
            outputTransformFlipped_180
            (invertOutputTransform trans)
    let transed = boxTransform box transform w h
    rendererScissor rend (Just transed)

frameHandler :: WSTag a => Double -> Output -> Way vs a ()
frameHandler secs out@Output {outputRoots = output, outputLayout = layers} = do
    enabled <- liftIO $ isOutputEnabled output
    needsSwap <- liftIO $ getOutputNeedsSwap output
    when (enabled && needsSwap) $ do
        comp <- wayCompositor <$> getState
        renderOn output (compRenderer comp) $ \age -> do
            let withDRegion = \act -> if age < 0 || age > 1
                then withRegion $ \region -> do
                        w <- fromIntegral <$> getWidth output
                        h <- fromIntegral <$> getHeight output
                        resetRegion region . Just $ WlrBox 0 0 w h
                        act region
                else withRegionCopy (outputDamage out) $ \region -> do
                        let (b1, b2) = outputOldDamage out
                        pixmanRegionUnion region b1
                        pixmanRegionUnion region b2
                        pixmanRegionUnion region (getOutputDamage output)
                        act region
            renderBody <- makeCallback $ handleLayers comp secs output layers
            liftIO $ withDRegion $ \region -> do
                notEmpty <- pixmanRegionNotEmpty region
                when notEmpty $ do
                    boxes <- pixmanRegionBoxes region
                    forM_ boxes $ \box -> do
                        scissorOutput (compRenderer comp) output $ boxToWlrBox box
                        liftIO $ rendererClear (compRenderer comp) $ Color 0.25 0.25 0.25 1

                    renderBody region

                    rendererScissor (compRenderer comp) Nothing
                    let (b1, b2) = outputOldDamage out
                    copyRegion b1 b2
                    copyRegion b2 $ outputDamage out
                    pixmanRegionUnion b2 (getOutputDamage output)
                    resetRegion (outputDamage out) Nothing

fieteHandler :: WSTag a => Double -> Output -> Way vs a ()
fieteHandler secs Output {outputRoots = output, outputLayout = layers} = do
    enabled <- liftIO $ isOutputEnabled output
    needsSwap <- liftIO $ getOutputNeedsSwap output
    when (enabled && needsSwap) $ do
        comp <- wayCompositor <$> getState
        renderOn output (compRenderer comp) $ \_ -> do
            let withDRegion act = withRegion $ \region -> do
                        w <- fromIntegral <$> getWidth output
                        h <- fromIntegral <$> getHeight output
                        resetRegion region . Just $ WlrBox 0 0 w h
                        act region

            renderBody <- makeCallback $ handleLayers comp secs output layers
            liftIO $ withDRegion $ \region -> do
                liftIO $ rendererClear (compRenderer comp) $ Color 0.25 0.25 0.25 1
                renderBody region
