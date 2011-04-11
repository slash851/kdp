﻿/**
 WvNetStream
 version 1.3
 04/30/2010
 Widevine extension to the NetStream object.  Required to handles trickplay.
**/

package com.kaltura.kdpfl.plugin.widevine
{
	import flash.external.ExternalInterface;
	import flash.net.Responder;
	import flash.net.NetConnection;
	import flash.net.NetStream;
	import flash.utils.Timer;
	import flash.utils.getTimer;
	import flash.events.TimerEvent;

	import com.kaltura.kdpfl.plugin.widevine.*
	
	public class WvNetStream extends NetStream
	{
		// maximun trick play speed to allow
		const MAX_SCALE:int	= 64;
		
		// start trick play at this speed.  
		const MIN_SCALE:int = 4;
		
		// do not allow seeks more than 1 per second
		const SEEK_INTERVAL = 100;
		
		// automatically switch to normal speed on seeks.
		const EXIT_TRICKPLAY_ON_SEEK:Boolean = true;
			
		private var myMovie:String;
		private var myErrorText:String;
		private var myCurrentMediaTime:Number;
		private var myPreviousMediaTime:Number;
		private var myWvMediaTime:Number;
		private var myPlayScale:int;
		private var myPlayStatus:Boolean;
		private var myPrevTimeGetMediaTimeCalled:Number;
		private var myIsBypassMode:Boolean;
		private var myConnection:WvNetConnection;
		private var myTimer:Timer;
		private var myResponder:Responder;
		private var myBitrates:Array;
		private var myCurrentBitrate:int;
		private var myMaxQualityLevel:int;
		private var myCurrentQualityLevel:int;
		private var myMaxScale:int;
		private var myAllowChapters:Boolean;
		private var myTickCounter:int;
		private var myScaleChangedTime:int;
		private var mySelectedTrack:int;
		private var myIsLiveStream:Boolean;
		
		// chapter support
		private var myChapterConnection:WvChapterConnection;

		public function WvNetStream(connection:WvNetConnection):void
		{
			myCurrentMediaTime 	= 0;
			myPreviousMediaTime	= 0;
			myPrevTimeGetMediaTimeCalled = 0;
			myCurrentQualityLevel = 0;
			myMaxQualityLevel 	= 0;
			myPlayScale	 		= 1;
			myIsBypassMode 		= false;
			myConnection 		= connection;
			myPlayStatus		= false;
			myWvMediaTime		= 0;
			myAllowChapters		= true;
			myChapterConnection	= new WvChapterConnection();
			myTickCounter		= 0;
			myScaleChangedTime  = 0;
			mySelectedTrack 	= 0;
			myIsLiveStream		= false;
			
			// Create a timer to keep current media time correct due to trickplay
			myTimer				= new Timer(100, 0);
			myTimer.addEventListener (TimerEvent.TIMER, tick);
			
			// Create a responder object for NetConnnection.call()
			myResponder = new Responder(onResponderResult, onResponderFault);
			
			setBypassMode (myConnection.IsBypassMode());
			super(myConnection);
		}
		///////////////////////////////////////////////////////////////////////////
		public override function play(... arguments):void
		{
			this.doPlay(arguments[0]);
		}		
		///////////////////////////////////////////////////////////////////////////
		function doPlay(movie:String):Number
		{
			myMovie = movie;
			
			myIsLiveStream = isLiveStream();
			
			if (IsBypassMode()) {
				if (myConnection.IsPdl()) {
					var theURL:String = myConnection.getNewURL();
					myMovie = theURL.substr(theURL.lastIndexOf("/")+1);
					super.play(theURL);
				}
				else {
					super.play(myMovie);
				}
			}
			else {
				super.play(myMovie);
			}
			myPlayStatus = true;
			
			return 0;
		}
		///////////////////////////////////////////////////////////////////
		public override function pause():void 
		{
			if (IsBypassMode()) {
				//trace("bypass, calling pause");
				super.pause();
				return;
			}
			
			if (myPlayScale != 1) {
				var mediaTime:Number = getCurrentMediaTime();
				try {
					myConnection.call("WidevineMediaTransformer.setPlayScale", myResponder, 1);
					super.seek(mediaTime);
					myScaleChangedTime = getTimer();
					//trace("[pause] set play scale:"+1+", seek to:"+mediaTime);
				}
				catch (errObject:Error) {
					myErrorText = errObject.message;
				}
			}
			myPlayStatus = false;
			myPlayScale	= 1;
			super.pause()
		}
		///////////////////////////////////////////////////////////////////
		public override function resume():void 
		{
			if (IsBypassMode()) {
				super.resume();
				return;
			}
			var mediaTime:Number = getCurrentMediaTime();
			resumeAt(mediaTime);
		}
		///////////////////////////////////////////////////////////////////
		public function resumeAt(offset:Number):void 
		{
			if ((myPlayScale != 1) && (EXIT_TRICKPLAY_ON_SEEK)){
				try {
					myConnection.call("WidevineMediaTransformer.setPlayScale", myResponder, 1);
					super.seek(offset);
					myScaleChangedTime  = getTimer();
				}
				catch (errObject:Error) {
					trace("Exception calling WidevineMediaTransformer.setPlayScale:" + errObject.message);
					myErrorText = errObject.message;
				}
			}
			myPlayStatus = true;
			
			// don't call resume if we are switching from trick-play to normal play.
			// The seek from above will resume playback.
			if (myPlayScale == 1) {
				try {
					myConnection.call("WidevineMediaTransformer.setPlayScale", myResponder, 1);
				}
				catch (errObject:Error) {
					trace("Exception calling WidevineMediaTransformer.setPlayScale:" + errObject.message);
					myErrorText = errObject.message;
				}
				super.resume();
			}
			myPlayScale = 1;
		}
		///////////////////////////////////////////////////////////////////
		public override function seek(offset:Number):void 
		{
			if (myPlayScale != 1) {
				this.resumeAt(offset);
			}
			else {
				super.seek(offset);
			}
		}
		///////////////////////////////////////////////////////////////////
		public override function close():void
		{
			trace("WvNetStream.close()");
			myTimer.stop();
			myChapterConnection.closeSocket();
			super.close();
		}
		///////////////////////////////////////////////////////////////////
		public function playForward():void  
		{
			if (IsBypassMode()) {
				return;
			}
			
			var mediaTime:Number 	= myCurrentMediaTime;
			var newScale:int 		= myPlayScale;
			
			// If we're paused, resume
			if (myPlayStatus == false) {
				myPlayStatus = true;
				super.resume();
			}
			
			if (newScale <= 1) {
				newScale = MIN_SCALE;			// start with min scale
			}
			else {	// increase fast forward speed
				newScale = newScale * 2;	
				if (newScale > MAX_SCALE) {		// limit max scale and wrap around
					newScale = MIN_SCALE ;		
				}
			}

			try {
				myScaleChangedTime = getTimer();
				myPlayScale = newScale;
	
				myConnection.call("WidevineMediaTransformer.setPlayScale", myResponder, newScale);
				super.seek(getCurrentMediaTime());	
			}
			catch (errObject:Error) {
				myErrorText = "WVSetPlayScale failed: " + errObject.message;
			}

			return;
		}
		///////////////////////////////////////////////////////////////////
		public function playRewind():void {
			
			if (IsBypassMode()) {
				return;
			}
			
			var mediaTime:Number 	= getCurrentMediaTime();
			var newScale:int 		= myPlayScale;

			// If we're paused, resume
			if (myPlayStatus == false) {
				myPlayStatus = true;
				super.resume();
			}
			
			if (newScale >= 1) {
				newScale = MIN_SCALE * -1;		// start with min scale
			}
			else {
				newScale = newScale * 2;		// increase fast rewind speed
				if (Math.abs(newScale) > MAX_SCALE) {
					newScale = MIN_SCALE * -1;	// limit max scale and warp around
				}
			}	
			
			try {
				//trace("Rewind - new scale:" + newScale + ", seeking to:" + mediaTime);
				myScaleChangedTime = getTimer();
				myPlayScale = newScale;
				
				myConnection.call("WidevineMediaTransformer.setPlayScale", myResponder, newScale);
				super.seek(mediaTime);
				
			}
			catch (errObject:Error) {
				myErrorText = "WVSetPlayScale failed: " + errObject.message;
			}
			return;
		}

		///////////////////////////////////////////////////////////////////////////
		public function getCurrentMediaTime():Number
		{
			if (!myTimer.running) {
				trace("Starting NetStream timer");
				myTimer.start();
			}
			
			if (IsBypassMode()) {
				return super.time;
			}
			return myCurrentMediaTime;
		}
		///////////////////////////////////////////////////////////////////////////
		public function getWvMediaTime():Number
		{
			return myWvMediaTime;
		}
		///////////////////////////////////////////////////////////////////////////
		public function getErrorText():String
		{
			return myErrorText;
		}
		///////////////////////////////////////////////////////////////////////////
		public function getPlayStatus():Boolean
		{
			return myPlayStatus;
		}
		///////////////////////////////////////////////////////////////////////////
		public function getPlayScale():int
		{
			return myPlayScale;
		}
		///////////////////////////////////////////////////////////////////////////
		public function setBypassMode(bypass:Boolean):void
		{
			if (myConnection) {
				myConnection.setBypassMode(bypass);
			}
			myIsBypassMode = bypass;
		}
		///////////////////////////////////////////////////////////////////////////
		public function IsBypassMode():Boolean
		{
			return myIsBypassMode;
		}	
		///////////////////////////////////////////////////////////////////////////
		public function isLiveStream():Boolean
		{
			if (myMovie.indexOf(".m3u8") != -1) {
				return true;
			}
			return false;
		}
		///////////////////////////////////////////////////////////////////////////
		public function sendTransitionEvent():void
		{
			myConnection.call("WidevineMediaTransformer.sendTransitionEvent", myResponder);
		}
		///////////////////////////////////////////////////////////////////////////
		// Selecting a track puts the adaptive streaming in manual mode.
		// Selecting the already selected track will put the adaptive streaming 
		// back into auto mode.
		public function selectTrack(track:int):void
		{
			// check is caller wants to go back to auto adaptive streaming.
			if (mySelectedTrack == track) {
				myCurrentQualityLevel = 0;
 				track = 0;
			}
			mySelectedTrack = track;
			myConnection.call("WidevineMediaTransformer.selectTrack", myResponder, mySelectedTrack);
			trace("Selected track:" + mySelectedTrack);
		}
		///////////////////////////////////////////////////////////////////////////
		public function getSelectedTrack():int
		{ 
			return mySelectedTrack;
		}

		///////////////////////////////////////////////////////////////////////////
		public function getCurrentBitrate():int
		{
			return myCurrentBitrate;
		}
		///////////////////////////////////////////////////////////////////////////
		public function getBitrates():Array
		{
			return myBitrates;
		}
		///////////////////////////////////////////////////////////////////////////
		public function getCurrentQualityLevel():int
		{
			return myCurrentQualityLevel;
		}
		///////////////////////////////////////////////////////////////////////////
		public function getMaxQualityLevel():int
		{
			return myMaxQualityLevel;
		}
		///////////////////////////////////////////////////////////////////////////
		public function getNumChapters():int
		{
			if (!myAllowChapters) {
				return 0;
			}
			return myChapterConnection.getNumChapters();
		}
		///////////////////////////////////////////////////////////////////////////
		public function getChapter(chapterNum:int):WvChapter
		{
			if (!myAllowChapters) {
				return null;
			}
			return myChapterConnection.getChapter(chapterNum);
		}
		///////////////////////////////////////////////////////////////////////////
		public function isChaptersReady():Boolean
		{
			if (getNumChapters() != -1){
				// trace ("getNumChapters() returned: " + getNumChapters());
				return myChapterConnection.isChaptersLoaded();
			}
			return false;
		}
		///////////////////////////////////////////////////////////////////////////
		public function parseTransitionMsg(fullMessage:String):void 
		{			
			if (fullMessage.length == 0) {
			    return;
			}
				
			var msg:Array = fullMessage.split(":");
			if (msg.length < 2) {
				return;
			}

			var currentQualityLevel:int = 0;
			var currentBitrate:int = 0;
			
			myBitrates = null;
			
			var bitrates:Array = msg[0].split(";");
			myBitrates = new Array(bitrates.length);
			
			// unsorted bitrates 
			for (var j:int=0; j<bitrates.length; j++) {
				myBitrates[j] = Number(bitrates[j]);
			}

			if (msg.length > 1) {
				// get the quality level
				var qualityLevel:int = Number(msg[1]);
				currentBitrate = bitrates[qualityLevel];
			}
			
			// order the bitrates from lowest to highest.
			var done:Boolean = false;
			while (!done) {
				done = true;
				var i:int;
				for (i=0; i<myBitrates.length-1; i++) {
					if (myBitrates[i+1] < myBitrates[i]) {	// bubble up 
						j = myBitrates[i];
						myBitrates[i] = myBitrates[i+1];
						myBitrates[i+1] = j;
						done = false;
					}
				}
			}
			
			if (msg.length > 1) {
				// set the quality level
				currentQualityLevel = 0;
				
				for (i=0; i<myBitrates.length; i++) {
					if (myBitrates[i] == currentBitrate) {
						currentQualityLevel = i+1;
						break;
					}
				}
				// convert from bytes to bits
				myCurrentBitrate 		= Math.round((currentBitrate * 8)/1000);
				myCurrentQualityLevel 	= currentQualityLevel;
				myMaxQualityLevel 		= bitrates.length;
			}
		}
		///////////////////////////////////////////////////////////////////////////
		// Create an onResult( ) method to handle results from the call to the remote method
		public function onResponderResult (result:Object):void 
		{
			
		}
		///////////////////////////////////////////////////////////////////////////
		public function onResponderFault(fault:Object):void 
		{
  			myErrorText = "responder fault: "+ fault;
		}
		///////////////////////////////////////////////////////////////////////////
		private function loadChapters():void
		{
			if (!myAllowChapters) {
				return;
			}
			// check is chapters are already loaded
			if (isChaptersReady()) {
				return;
			}
			
			var commURL:String;
			try {
				commURL = String(ExternalInterface.call("WVGetCommURL", super.time ));
				//trace("commURL:" + commURL);
			}
			catch (e:Error) {
				//trace("Error: exception from WVGetCommURL():" + e.message);
				return;
			}
			if (commURL == "error") {
				//trace("Error: WVGetCommURL() returned error");
				return;
			}
			if (commURL == "") {
				//trace("Error: WVGetCommURL() returned empty string");
				return;
			}
			
			var port:int = 0;
			var host:String;
			
			var i:int = commURL.indexOf("://")
			if (i == 0) {
				//trace("Error parsing start of host from:" + commURL);
				return;
			}
			var j:int = commURL.indexOf(":", i+3);
			if (j == 0) {
				//trace("Error parsing end of host from:" + commURL);
				return;
			}
			i += 3;
			j += 1;
			host = commURL.substr(i, (j-i-1));
			//trace("host:" + host);
			
			i = commURL.indexOf("/", j);
			i += 1;
			
			port = int(commURL.substr(j, (i-j-1)));
			//trace("port:" + commURL.substr(j, i-j-1));
																		
			if (port == 0) {
				//trace("Error parsing port from:" + commURL);
				return;
			}
			trace("Initializeing chapter connection...");
			myChapterConnection.init(host, port);
		}

		///////////////////////////////////////////////////////////////////////////
		private function tick(event:TimerEvent):void
		{
			if (IsBypassMode()) {
				return;
			}
			
			// check chapters approx 2 second interval 
			if (++myTickCounter > 20) {
				myTickCounter = 0;
				loadChapters();
			}
			
			var now:Number = getTimer();
					
			if ((myPlayScale == 1) && (!myIsLiveStream)) {
				// don't use flash's netstream time too soon after exiting trickplay
				if ((myScaleChangedTime + 1000) < now) {
					myPreviousMediaTime = myCurrentMediaTime;
					myCurrentMediaTime 	= super.time;
					return;
				}
			}
			
			// avoid calling WVGetMediaTime too much
			if ((myPrevTimeGetMediaTimeCalled + (1000/myPlayScale)) < now) {
				// bug: for some reason, getting time right after changing rewind speed returns
				// the flash current time instead of the adjusted time.
				if  ((myScaleChangedTime + 1000) < now)  {
					myPreviousMediaTime = myCurrentMediaTime;
					var mediaTime:String = ExternalInterface.call("WVGetMediaTime", super.time);
					if (mediaTime == "ERROR") {
						trace("WVGetMediaTime returned error:" + mediaTime);
					}
					else {
						myWvMediaTime 	= Number(mediaTime);
						myCurrentMediaTime 	= myWvMediaTime;
						myPrevTimeGetMediaTimeCalled = now;
					}
				}
			}
			return;
		}
	}   // class
}  // package