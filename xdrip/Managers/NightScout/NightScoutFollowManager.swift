import Foundation
import os
import AVFoundation
import AudioToolbox

/// instance of this class will do the follower functionality. Just make an instance, it will listen to the settings, do the regular download if needed - it could be deallocated when isMaster setting in Userdefaults changes, but that's not necessary to do
class NightScoutFollowManager: NSObject {
    
    // MARK: - public properties
    
    // MARK: - private properties
    
    /// to solve problem that sometemes UserDefaults key value changes is triggered twice for just one change
    private let keyValueObserverTimeKeeper: KeyValueObserverTimeKeeper = KeyValueObserverTimeKeeper()
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryNightScoutFollowManager)
    
    /// when to do next download
    private var nextFollowDownloadTimeStamp: Date
    
    /// reference to coredatamanager
    private var coreDataManager: CoreDataManager
    
    /// reference to BgReadingsAccessor
    private var bgReadingsAccessor: BgReadingsAccessor
    
    /// delegate to pass back glucosedata
    private (set) weak var nightScoutFollowerDelegate: NightScoutFollowerDelegate?
    
    /// AVAudioPlayer to use
    private var audioPlayer: AVAudioPlayer?
    
    /// constant for key in ApplicationManager.shared.addClosureToRunWhenAppWillEnterForeground - create playsoundtimer
    private let applicationManagerKeyResumePlaySoundTimer = "NightScoutFollowerManager-ResumePlaySoundTimer"
    
    /// constant for key in ApplicationManager.shared.addClosureToRunWhenAppDidEnterBackground - invalidate playsoundtimer
    private let applicationManagerKeySuspendPlaySoundTimer = "NightScoutFollowerManager-SuspendPlaySoundTimer"
    
    /// closure to call when downloadtimer needs to be invalidated, eg when changing from master to follower
    private var invalidateDownLoadTimerClosure: (() -> Void)?
    
    // timer for playsound
    private var playSoundTimer: RepeatingTimer?

    // MARK: - initializer
    
    /// initializer
    public init(coreDataManager: CoreDataManager, nightScoutFollowerDelegate: NightScoutFollowerDelegate) {
        
        // initialize nextFollowDownloadTimeStamp to now, which is at the moment FollowManager is instantiated
        nextFollowDownloadTimeStamp = Date()
        
        // initialize non optional private properties
        self.coreDataManager = coreDataManager
        self.bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        self.nightScoutFollowerDelegate = nightScoutFollowerDelegate
        
        // set up audioplayer
        if let url = Bundle.main.url(forResource: ConstantsSuspensionPrevention.soundFileName, withExtension: "")  {
            
            // create audioplayer
            do {
                
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                
            } catch let error {
                
                trace("in init, exception while trying to create audoplayer, error = %{public}@", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .error, error.localizedDescription)
                
            }
            
        }

        // call super.init
        super.init()
        
        // changing from follower to master or vice versa also requires ... attention
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.isMaster.rawValue, options: .new, context: nil)
        // setting nightscout url also does require action
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutUrl.rawValue, options: .new, context: nil)
        // setting nightscout API_SECRET also does require action
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutAPIKey.rawValue, options: .new, context: nil)
        // setting nightscout authentication token also does require action
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightscoutToken.rawValue, options: .new, context: nil)
        // change value of nightscout enabled
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutEnabled.rawValue, options: .new, context: nil)

        verifyUserDefaultsAndStartOrStopFollowMode()
    }
    
    // MARK: - public functions
    
    /// creates a bgReading for reading downloaded from NightScout
    /// - parameters:
    ///     - followGlucoseData : glucose data from which new BgReading needs to be created
    /// - returns:
    ///     - BgReading : the new reading, not saved in the coredata
    public func createBgReading(followGlucoseData:NightScoutBgReading) -> BgReading {
        // for dev : creation of BgReading is done in seperate static function. This allows to do the BgReading creation in other place, as is done also for readings received from a transmitter.
        
        // create new bgReading
        // using sgv as value for rawData because in some case these values are not available in NightScout
        let bgReading = BgReading(timeStamp: followGlucoseData.timeStamp, sensor: nil, calibration: nil, rawData: followGlucoseData.sgv, deviceName: nil, nsManagedObjectContext: coreDataManager.mainManagedObjectContext)

        // set calculatedValue
        bgReading.calculatedValue = followGlucoseData.sgv
        
        // set calculatedValueSlope
        let (calculatedValueSlope, hideSlope) = findSlope()
        bgReading.calculatedValueSlope = calculatedValueSlope
        bgReading.hideSlope = hideSlope
        
        return bgReading
        
    }
    
    // MARK: - private functions
    
    /// taken from xdripplus
    ///
    /// updates bgreading
    ///
    private func findSlope() -> (calculatedValueSlope:Double, hideSlope:Bool) {
        
        // init returnvalues
        var hideSlope = true
        var calculatedValueSlope = 0.0

        // get last readings
        let last2Readings = bgReadingsAccessor.getLatestBgReadings(limit: 3, howOld: 1, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
        
        // if more thant 2 readings, calculate slope and hie
        if last2Readings.count >= 2 {
            let (slope, hide) = last2Readings[0].calculateSlope(lastBgReading:last2Readings[1]);
            calculatedValueSlope = slope
            hideSlope = hide
        }

        return (calculatedValueSlope, hideSlope)
        
    }

    
    /// download recent readings from nightScout, send result to delegate, and schedule new download
    @objc private func download() {
        
        trace("in download", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .info)

        trace("    setting nightScoutSyncTreatmentsRequired to true, this will also initiate a treatments sync", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .info)
        UserDefaults.standard.nightScoutSyncTreatmentsRequired = true
        
        // nightscout URl must be non-nil - could be that url is not valid, this is not checked here, the app will just retry every x minutes
        guard let nightScoutUrl = UserDefaults.standard.nightScoutUrl else {return}
        
        // maximum timeStamp to download initially set to 1 day back
        var timeStampOfFirstBgReadingToDowload = Date(timeIntervalSinceNow: TimeInterval(-Double(ConstantsFollower.maxiumDaysOfReadingsToDownload) * 24.0 * 3600.0))
        
        // check timestamp of lastest stored bgreading with calculated value, if more recent then use this as timeStampOfFirstBgReadingToDowload
        let latestBgReadings = bgReadingsAccessor.getLatestBgReadings(limit: nil, howOld: 1, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
        if latestBgReadings.count > 0 {
            timeStampOfFirstBgReadingToDowload = max(latestBgReadings[0].timeStamp, timeStampOfFirstBgReadingToDowload)
        }
        
        // calculate count, which is a parameter in the nightscout API - divide by 300, we're assuming readings every 5 minutes = 300 seconds
        let count = Int(-timeStampOfFirstBgReadingToDowload.timeIntervalSinceNow / 300 + 1)
        
        // ceate endpoint to get latest entries
        let latestEntriesEndpoint = Endpoint.getEndpointForLatestNSEntries(hostAndScheme: nightScoutUrl, count: count, token: UserDefaults.standard.nightscoutToken)
        
        // create downloadTask and start download
        if let url = latestEntriesEndpoint.url {
            
            // Create Request - this way we can add authentication in follower mode in order to pull data from Nightscout sites with AUTH_DEFAULT_ROLES configured to deny read access
            var request = URLRequest(url: url)
            
            if let apiKey = UserDefaults.standard.nightScoutAPIKey {
                request.setValue(apiKey.sha1(), forHTTPHeaderField:"api-secret")
            }
            
            let task = URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
                
                trace("in download, finished task", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .info)
                
                // get array of FollowGlucoseData from json
                var followGlucoseDataArray = [NightScoutBgReading]()
                self.processDownloadResponse(data: data, urlResponse: response, error: error, followGlucoseDataArray: &followGlucoseDataArray)
                
                trace("    finished download,  %{public}@ readings", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .info, followGlucoseDataArray.count.description)
                
                // call to delegate and rescheduling the timer must be done in main thread;
                DispatchQueue.main.sync {
                    
                    // call delegate nightScoutFollowerInfoReceived which will process the new readings
                    if let nightScoutFollowerDelegate = self.nightScoutFollowerDelegate {
                        nightScoutFollowerDelegate.nightScoutFollowerInfoReceived(followGlucoseDataArray: &followGlucoseDataArray)
                    }

                    // schedule new download
                    self.scheduleNewDownload()

                }
                
            })
            
            trace("in download, calling task.resume", log: log, category: ConstantsLog.categoryNightScoutFollowManager, type: .info)
            task.resume()
            
        }

    }
    
    /// schedule new download with timer, when timer expires download() will be called
    private func scheduleNewDownload() {
        
        trace("in scheduleNewDownload", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .info)
        
        // schedule a timer for 15 seconds and assign it to a let property
        let downloadTimer = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(self.download), userInfo: nil, repeats: false)
        
        // assign invalidateDownLoadTimerClosure to a closure that will invalidate the downloadTimer
        invalidateDownLoadTimerClosure = {
            downloadTimer.invalidate()
        }
    }
    
    /// process result from download from NightScout
    /// - parameters:
    ///     - data : data as result from dataTask
    ///     - urlResponse : urlResponse as result from dataTask
    ///     - error : error as result from dataTask
    ///     - followGlucoseData : array input by caller, result will be in that array. Can be empty array. Array must be initialized to empty array by caller
    /// - returns: FollowGlucoseData , possibly empty - first entry is the youngest
    private func processDownloadResponse(data:Data?, urlResponse:URLResponse?, error:Error?, followGlucoseDataArray:inout [NightScoutBgReading] ) {
        
        // log info
        trace("in processDownloadResponse", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .info)
        
        // if error log an error
        if let error = error {
            trace("    failed to download, error = %{public}@", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .error, error.localizedDescription)
            return
        }
        
        // if data not nil then check if response is nil
        if let data = data {
            /// if response not nil then process data
            if let urlResponse = urlResponse as? HTTPURLResponse {
                if urlResponse.statusCode == 200 {
                    
                    // convert data to String for logging purposes
                    var dataAsString = ""
                    if let aa = String(data: data, encoding: .utf8) {
                        dataAsString = aa
                    }
                    
                    // try json deserialization
                    if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
                        
                        // it should be an array
                        if let array = json as? [Any] {
                            
                            // iterate through the entries and create glucoseData
                            for entry in array {

                                if let entry = entry as? [String:Any] {
                                    if let followGlucoseData = NightScoutBgReading(json: entry) {
                                        
                                        // insert entry chronologically sorted, first is the youngest
                                        if followGlucoseDataArray.count == 0 {
                                            followGlucoseDataArray.append(followGlucoseData)
                                        } else {
                                            var elementInserted = false
                                            loop : for (index, element) in followGlucoseDataArray.enumerated() {
                                                if element.timeStamp < followGlucoseData.timeStamp {
                                                    followGlucoseDataArray.insert(followGlucoseData, at: index)
                                                    elementInserted = true
                                                    break loop
                                                }
                                            }
                                            if !elementInserted {
                                                followGlucoseDataArray.append(followGlucoseData)
                                            }
                                        }

                                    } else {
                                        trace("     failed to create glucoseData, entry = %{public}@", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .error, entry.description)
                                    }
                                }
                            }
                            
                        } else {
                            trace("     json deserialization failed, result is not a json array, data received = %{public}@", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .error, dataAsString)
                        }
                        
                    } else {
                        trace("     json deserialization failed, data received = %{public}@", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .error, dataAsString)
                    }
                    
                } else {
                    trace("     urlResponse.statusCode  is not 200 value = %{public}@", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .error, urlResponse.statusCode.description)
                }
            } else {
                trace("    data is nil", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .error)
            }
        } else {
            trace("    urlResponse is not HTTPURLResponse", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .error)
        }
    }
    
    /// disable suspension prevention by removing the closures from ApplicationManager.shared.addClosureToRunWhenAppDidEnterBackground and ApplicationManager.shared.addClosureToRunWhenAppWillEnterForeground
    private func disableSuspensionPrevention() {
        
        // stop the timer for now, might be already suspended but doesn't harm
        if let playSoundTimer = playSoundTimer {
            playSoundTimer.suspend()
        }
        
        // no need anymore to resume the player when coming in foreground
        ApplicationManager.shared.removeClosureToRunWhenAppDidEnterBackground(key: applicationManagerKeyResumePlaySoundTimer)
        
        // no need anymore to suspend the soundplayer when entering foreground, because it's not even resumed
        ApplicationManager.shared.removeClosureToRunWhenAppWillEnterForeground(key: applicationManagerKeySuspendPlaySoundTimer)
        
    }
    
    /// launches timer that will regular play sound - this will be played only when app goes to background
    private func enableSuspensionPrevention() {
        
        // create playSoundTimer
        playSoundTimer = RepeatingTimer(timeInterval: TimeInterval(Double(ConstantsSuspensionPrevention.interval)), eventHandler: {
                // play the sound
            
             trace("in eventhandler checking if audioplayer exists", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .info)
            
                if let audioPlayer = self.audioPlayer, !audioPlayer.isPlaying {
                    trace("playing audio", log: self.log, category: ConstantsLog.categoryNightScoutFollowManager, type: .info)
                    audioPlayer.play()
                }
            })
        
        // schedulePlaySoundTimer needs to be created when app goes to background
        ApplicationManager.shared.addClosureToRunWhenAppDidEnterBackground(key: applicationManagerKeyResumePlaySoundTimer, closure: {
            if let playSoundTimer = self.playSoundTimer {
                playSoundTimer.resume()
            }
            if let audioPlayer = self.audioPlayer, !audioPlayer.isPlaying {
                audioPlayer.play()
            }
        })

        // schedulePlaySoundTimer needs to be invalidated when app goes to foreground
        ApplicationManager.shared.addClosureToRunWhenAppWillEnterForeground(key: applicationManagerKeySuspendPlaySoundTimer, closure: {
            if let playSoundTimer = self.playSoundTimer {
                playSoundTimer.suspend()
            }
        })
    }
    
    /// verifies values of applicable UserDefaults and either starts or stops follower mode, inclusive call to enableSuspensionPrevention or disableSuspensionPrevention - also first download is started if applicable
    private func verifyUserDefaultsAndStartOrStopFollowMode() {
        if !UserDefaults.standard.isMaster && UserDefaults.standard.nightScoutUrl != nil && UserDefaults.standard.nightScoutEnabled {
            
            // this will enable the suspension prevention sound playing
            enableSuspensionPrevention()
            
            // do initial download, this will also schedule future downloads
            download()
            
        } else {
            
            // disable the suspension prevention
            disableSuspensionPrevention()
            
            // invalidate the downloadtimer
            if let invalidateDownLoadTimerClosure = invalidateDownLoadTimerClosure {
                invalidateDownLoadTimerClosure()
            }
        }
    }
    
    // MARK: - overriden function
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        if let keyPath = keyPath {
            
            if let keyPathEnum = UserDefaults.Key(rawValue: keyPath) {
                
                switch keyPathEnum {
                    
                case UserDefaults.Key.isMaster, UserDefaults.Key.nightScoutUrl, UserDefaults.Key.nightScoutEnabled, UserDefaults.Key.nightScoutAPIKey, UserDefaults.Key.nightscoutToken :
                    
                    // change by user, should not be done within 200 ms
                    if (keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 200)) {
                        
                        verifyUserDefaultsAndStartOrStopFollowMode()
                        
                    }
                    
                default:
                    break
                }
            }
        }
    }
    

}
