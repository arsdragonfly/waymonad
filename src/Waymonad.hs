{-
waymonad A wayland compositor in the spirit of xmonad
Copyright (C) 2017  Markus Ongyerth

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

Reach us at https://github.com/ongy/waymonad
-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Waymonad
    ( get
    , modify

    , floatBelow

    , KeyBinding
    , BindingMap
    , LogFun

    , WayBindingState (..)

    , Way
    , getState
    , getSeat
    , runWay
    , unliftWay
    , makeCallback
    , makeCallback2
    , setCallback
    , withSeat
    , getViewSet

    , WayLoggers (..)
    , Logger (..)
    , getLoggers

    , EventClass
    , SomeEvent
    , getEvent
    , sendEvent

    , getSeats
    )
where

import System.IO.Unsafe (unsafeInterleaveIO)

import Control.Applicative ((<|>))
import Control.Monad (forM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader(..), local)
import Control.Monad.Trans.Class (MonadTrans (..))
import Data.IORef (IORef, modifyIORef, readIORef)
import Data.List (find)
import Data.Maybe (maybeToList, listToMaybe)
import Data.Typeable (cast)

import Graphics.Wayland.WlRoots.Box (Point (..), WlrBox (..))

import {-# SOURCE #-} Input.Seat (Seat, getPointerFocus)
import Utility (doJust)
import View (View, getViewEventSurface, getViewBox)
import Waymonad.Types

import qualified Data.Set as S



get :: (MonadReader (IORef a) m, MonadIO m) => m a
get = liftIO . readIORef =<< ask

modify :: (MonadReader (IORef a) m, MonadIO m) => (a -> a) -> m ()
modify fun = do
    ref <- ask
    liftIO $ modifyIORef ref fun

floatsBelow
    :: Point
    -> Way vs a [(View, Double, Double)]
floatsBelow (Point x y) = do
    views <- liftIO . fmap S.toList . readIORef . wayFloating =<< getState
    candidates <- liftIO $ forM views $
        \view -> unsafeInterleaveIO $ do
            WlrBox vx vy _ _ <- getViewBox view
            doJust (getViewEventSurface view (fromIntegral $ x - vx) (fromIntegral $ y - vy)) $ \_ ->
                pure $ Just (view, (fromIntegral $ x - vx), (fromIntegral $ y - vy))

    pure $ foldMap maybeToList candidates

floatBelow
    :: Point
    -> Way vs a (Maybe (View, Double, Double))
floatBelow p = do
    floats <- floatsBelow p
    seat <- getSeat

    -- TODO: Prettify this =.=
    case seat of
        Nothing -> pure $ listToMaybe floats
        Just s -> do
            focused <- getPointerFocus s
            case focused of
                Nothing -> pure $ listToMaybe floats
                Just f ->
                    pure $ find (\(v, _, _) -> v == f) floats <|> listToMaybe floats


getEvent :: EventClass e => SomeEvent -> Maybe e
getEvent (SomeEvent e) = cast e

sendEvent :: EventClass e => e -> Way vs a ()
sendEvent e = flip wayEventHook (SomeEvent e) =<< getState

getLoggers :: Way vs a WayLoggers
getLoggers = wayLoggers <$> getState

getState :: Way vs a (WayBindingState vs a)
getState = ask

getSeat :: Way vs a (Maybe Seat)
getSeat = do
    current <- wayCurrentSeat <$> getState
    case current of
        Just _ -> pure current
        Nothing -> do
            seats <- liftIO . readIORef . wayBindingSeats =<< getState
            pure $ case seats of
                [x] -> Just x
                _ -> Nothing

getViewSet :: Way vs a vs
getViewSet = liftIO . readIORef . wayBindingState =<< getState

unliftWay :: Way vs a b -> Way vs a (IO b)
unliftWay act = do
    state <- getState
    pure $ runWay state act

makeCallback :: (c -> Way vs a b) -> Way vs a (c -> IO b)
makeCallback act = do
    state <- getState
    pure $ runWay state . act

makeCallback2 :: (c -> d -> Way vs a b) -> Way vs a (c -> d -> IO b)
makeCallback2 act = curry <$> makeCallback (uncurry act)

setCallback :: (c -> Way vs a b) -> ((c -> IO b) -> IO d) -> Way vs a d
setCallback act fun = do
    ioAct <- makeCallback act
    liftIO $ fun ioAct


withSeat :: Maybe Seat -> Way vs a b -> Way vs a b
withSeat seat (Way m) = Way $ local (\s -> s {wayCurrentSeat = seat}) m

getSeats :: Way vs a [Seat]
getSeats = liftIO . readIORef . wayBindingSeats =<< getState

