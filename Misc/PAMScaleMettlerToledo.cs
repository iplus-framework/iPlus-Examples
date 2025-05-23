using gip.core.autocomponent;
using gip.core.datamodel;
using gip.core.processapplication;
using gip.mes.processapplication;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace systec.mes.processapplication
{
    //TODO: Implement logic for continuous scale reading (separate thread)
    [ACClassInfo(Const.PackName_VarioAutomation, "en{'PAMScaleMettlerToledo TCP'}de{'PAMScaleMettlerToledo TCP'}", Global.ACKinds.TPAModule, Global.ACStorableTypes.Required, false, true)]
    public class PAMScaleMettlerToledo : PAEScaleCalibratableMES
    {
        #region c'tors
        public PAMScaleMettlerToledo(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
            _SICSLevel = new ACPropertyConfigValue<ushort>(this, "SICSLevel", 1);
        }

        public override bool ACInit(Global.ACStartTypes startChildMode = Global.ACStartTypes.Automatic)
        {
            if (!base.ACInit(startChildMode))
                return false;
            CurrentScaleMode = PAScaleMode.Idle;
            return true;
        }

        public override bool ACPostInit()
        {
            _ = SICSLevel;
            if (PollingInterval <= 0)
                PollingInterval = 2000;
            if (ACOperationMode == ACOperationModes.Live)
            {
                _ShutdownEvent = new ManualResetEvent(false);
                _PollThread = new ACThread(Poll);
                _PollThread.Name = "ACUrl:" + this.GetACUrl() + ";Poll();";
                _PollThread.Start();
            }

            return base.ACPostInit();
        }

        public override bool ACDeInit(bool deleteACClassTask = false)
        {
            if (_PollThread != null)
            {
                if (_ShutdownEvent != null && _ShutdownEvent.SafeWaitHandle != null && !_ShutdownEvent.SafeWaitHandle.IsClosed)
                    _ShutdownEvent.Set();
                if (!_PollThread.Join(5000))
                    _PollThread.Abort();
                _PollThread = null;
            }
            StopReadWeightData();
            ClosePort();
            return base.ACDeInit(deleteACClassTask);
        }
        #endregion

        #region Info
        // METTLER TOLEDO SICS PROTOCOL:
        /*
        S – Send stable weight value
        Command: S
        Send the current stable net weight value.
        
        Response formats:
        S S WeightValue Unit         - Current stable weight value
        S I                         - Command not executable (timeout, not stable)
        S +                         - Terminal in overcapacity range
        S -                         - Terminal in undercapacity range
        
        Example: "S S    12.345 g" (spaces are significant)
        */
        #endregion

        #region Enums
        public enum PAScaleMode : short
        {
            Disconnect = 0,
            Init = 1,
            Idle = 2,
            ReadingWeightsRequested = 3,
            ReadingWeights = 4,
        }
        #endregion

        #region Properties

        #region config
        private ACPropertyConfigValue<ushort> _SICSLevel;
        [ACPropertyConfig("en{'SICS protocol level'}de{'SICS Protokoll-Level'}")]
        public ushort SICSLevel
        {
            get => _SICSLevel.ValueT;
            set => _SICSLevel.ValueT = value;
        }
        #endregion

        #region TCP-Communication
        [ACPropertyInfo(true, 401, "Config", "en{'Communication on'}de{'Kommunikation ein'}", DefaultValue = false)]
        public bool TCPCommEnabled { get; set; }

        protected TcpClient _tcpClient = null;
        [ACPropertyInfo(9999)]
        public TcpClient TcpClient
        {
            get { return _tcpClient; }
        }

        protected readonly ACMonitorObject _61000_LockPort = new ACMonitorObject(61000);

        [ACPropertyInfo(true, 402, "Config", "en{'IP-Address'}de{'IP-Adresse'}", DefaultValue = "192.168.1.100")]
        public string ServerIPV4Address
        {
            get;
            set;
        }

        [ACPropertyInfo(true, 404, "Config", "en{'Port-No.'}de{'Port-Nr.'}", DefaultValue = (int)8001)]
        public int PortNo
        {
            get;
            set;
        }

        [ACPropertyInfo(true, 405, "Config", "en{'Read-Timeout [ms]'}de{'Lese-Timeout [ms]'}", DefaultValue = 2000)]
        public int ReceiveTimeout
        {
            get;
            set;
        }

        [ACPropertyInfo(true, 406, "Config", "en{'Write-Timeout [ms]'}de{'Schreibe-Timeout [ms]'}", DefaultValue = 2000)]
        public int SendTimeout
        {
            get;
            set;
        }

        [ACPropertyInfo(true, 400, "Config", "en{'Polling [ms]'}de{'Abfragezyklus [ms]'}", DefaultValue = 1000)]
        public int PollingInterval { get; set; }

        [ACPropertyInfo(true, 407, "Config", "en{'Command terminator'}de{'Befehlsabschluss'}", DefaultValue = "\r\n")]
        public string CommandTerminator { get; set; }

        #endregion

        #region Broadcast-Properties

        public IACContainerTNet<bool> _IsConnected = null;
        [ACPropertyBindingSource]
        public IACContainerTNet<bool> IsConnected
        {
            get
            {
                return _IsConnected;
            }
            set
            {
                _IsConnected = value;
            }
        }

        [ACPropertyBindingSource(407, "", "en{'Scale mode'}de{'Modus Waage'}", "", false, true)]
        public IACContainerTNet<short> ScaleMode { get; set; }

        public PAScaleMode CurrentScaleMode
        {
            get
            {
                return (PAScaleMode)ScaleMode.ValueT;
            }
            set
            {
                ScaleMode.ValueT = (short)value;
            }
        }

        private DateTime _LastWrite = DateTime.Now;

        [ACPropertyBindingSource(408, "", "en{'Last weight'}de{'Letztes Gewicht'}")]
        public IACContainerTNet<string> LastWeight { get; set; }

        [ACPropertyBindingSource(409, "Error", "en{'Communication alarm'}de{'Communication-Alarm'}", "", false, false)]
        public IACContainerTNet<PANotifyState> CommAlarm { get; set; }

        [ACPropertyBindingSource(410, "", "en{'Scale status'}de{'Waagen-Status'}", "", false, true)]
        public IACContainerTNet<string> ScaleStatus { get; set; }

        [ACPropertyBindingSource(411, "", "en{'Weight unit'}de{'Gewichtseinheit'}", "", false, true)]
        public IACContainerTNet<string> WeightUnit { get; set; }

        #endregion

        #endregion

        #region Methods

        #region Thread
        protected ManualResetEvent _ShutdownEvent;
        ACThread _PollThread;
        private void Poll()
        {
            try
            {
                int pollInterval = PollingInterval;
                while (!_ShutdownEvent.WaitOne(pollInterval, false))
                {
                    pollInterval = PollingInterval;
                    _PollThread.StartReportingExeTime();

                    if (CurrentScaleMode == PAScaleMode.ReadingWeights && IsEnabledStartReadWeightData())
                        PollWeightData();

                    _PollThread.StopReportingExeTime();
                }
            }
            catch (ThreadAbortException ec)
            {
                Messages.LogException("PAMScaleMettlerToledo", "Poll", ec);
            }
        }

        protected void PollWeightData()
        {
            ReadWeight(true);
        }

        #endregion

        #region Methods => Connection

        [ACMethodInteraction("Comm", "en{'Open Connection'}de{'Öffne Verbindung'}", 200, true)]
        public void OpenPort()
        {
            if (!IsEnabledOpenPort())
                return;
            
            _tcpClient = new System.Net.Sockets.TcpClient();
            using (ACMonitor.Lock(_61000_LockPort))
            {
                if (this.SendTimeout > 0)
                    _tcpClient.SendTimeout = this.SendTimeout;
                if (this.ReceiveTimeout > 0)
                    _tcpClient.ReceiveTimeout = this.ReceiveTimeout;

                try
                {
                    if (!this.TcpClient.Connected)
                    {
                        if (!String.IsNullOrEmpty(this.ServerIPV4Address))
                        {
                            IPAddress ipAddress = IPAddress.Parse(this.ServerIPV4Address);
                            this.TcpClient.Connect(ipAddress, PortNo);
                        }
                    }
                }
                catch (Exception e)
                {
                    CommAlarm.ValueT = PANotifyState.AlarmOrFault;
                    if (IsAlarmActive(CommAlarm, e.Message) == null)
                        Messages.LogException(GetACUrl(), "PAMScaleMettlerToledo.OpenPort()", e.Message);
                    OnNewAlarmOccurred(CommAlarm, e.Message, true);
                }
                IsConnected.ValueT = this.TcpClient.Connected;
            }
        }

        public bool IsEnabledOpenPort()
        {
            if (!TCPCommEnabled || (ACOperationMode != ACOperationModes.Live))
                return false;
            if (this.TcpClient == null)
            {
                if (String.IsNullOrEmpty(this.ServerIPV4Address))
                    return false;
                return true;
            }
            return !this.TcpClient.Connected;
        }

        [ACMethodInteraction("Comm", "en{'Close Connection'}de{'Schliesse Verbindung'}", 201, true)]
        public void ClosePort()
        {
            if (!IsEnabledClosePort())
                return;
            if (this.TcpClient != null)
            {
                using (ACMonitor.Lock(_61000_LockPort))
                {
                    if (this.TcpClient.Connected)
                        this.TcpClient.Close();
                    _tcpClient = null;
                }
            }
            IsConnected.ValueT = false;
        }

        public bool IsEnabledClosePort()
        {
            if (this.TcpClient == null)
                return false;
            return this.TcpClient.Connected;
        }

        #endregion

        #region Commands
        [ACMethodInteraction("Comm", "en{'Start reading weights'}de{'Starte Gewichtsdaten lesen'}", 202, true)]
        public void StartReadWeightData()
        {
            if (!IsEnabledStartReadWeightData())
                return;
            CurrentScaleMode = PAScaleMode.ReadingWeights;
        }

        public bool IsEnabledStartReadWeightData()
        {
            return TCPCommEnabled;
        }

        [ACMethodInteraction("Comm", "en{'Stop reading weights'}de{'Stoppe Gewichtsdaten lesen'}", 203, true)]
        public void StopReadWeightData()
        {
            if (!IsEnabledStopReadWeightData())
                return;
            CurrentScaleMode = PAScaleMode.Idle;
        }

        public bool IsEnabledStopReadWeightData()
        {
            return TCPCommEnabled;
        }

        [ACMethodInteraction("", "en{'Read weight'}de{'Gewicht lesen'}", 200, true)]
        public void ReadWeightInt()
        {
            var result = ReadWeight();
            if (result != null)
            {
                this.ActualValue.ValueT = result.Weight;
                Messages.LogDebug(this.GetACUrl(), "ReadWeightInt()", result.ToString());
            }
        }

        public bool IsEnabledReadWeightInt()
        {
            return TCPCommEnabled;
        }

        [ACMethodInfo("", "en{'Read weight'}de{'Gewicht lesen'}", 201, true)]
        public SICSWeightResult ReadWeight(bool continuous = false)
        {
            return ReadSICSWeight();
        }

        #endregion

        #region overrides
        public override Msg RegisterAlibiWeight()
        {
            // Delegate to other Thread because of Socket-Blocking
            if (!IsSimulationOn && TCPCommEnabled)
            {
                ApplicationManager.ApplicationQueue.Add(() => { base.RegisterAlibiWeight(); });
                return null;
            }
            else
                return base.RegisterAlibiWeight();
        }

        public override Msg OnRegisterAlibiWeight()
        {
            if (!IsEnabledOnRegisterAlibiWeight())
                return null;

            if (IsSimulationOn)
                SimulateAlibi();
            else
                ReadSICSWeight();
            return null;
        }

        public override bool IsEnabledOnRegisterAlibiWeight()
        {
            return TCPCommEnabled || IsSimulationOn;
        }

        public override void SetZero()
        {
            if (!IsSimulationOn && TCPCommEnabled)
            {
                ApplicationManager.ApplicationQueue.Add(() => { SetZeroInternal(); });
                return;
            }
            base.SetZero();
        }

        public override void Tare()
        {
            if (!IsSimulationOn && TCPCommEnabled)
            {
                ApplicationManager.ApplicationQueue.Add(() => { TareInternal(); });
                return;
            }
            base.Tare();
        }

        #endregion

        #region Internal
        private SICSWeightResult ReadSICSWeight()
        {
            double weight = -99999;
            string status = "Error";
            string unit = "";
            string errorMessage = null;

            try
            {
                if (!IsConnected.ValueT)
                {
                    OpenPort();
                    if (TcpClient == null || !TcpClient.Connected)
                        return ReportError("Can not open TCP/IP-Port!");
                }

                using (ACMonitor.Lock(_61000_LockPort))
                {
                    NetworkStream ns = TcpClient.GetStream();
                    if (ns == null || !ns.CanWrite)
                    {
                        ClosePort();
                        return ReportError("Can not write to stream!");
                    }

                    if ((DateTime.Now - _LastWrite).TotalMilliseconds < 500)
                        Thread.Sleep(500);

                    // Send SICS command "S" to get stable weight
                    string command = "S" + (CommandTerminator ?? "\r\n");
                    Byte[] data = Encoding.ASCII.GetBytes(command);
                    ns.Write(data, 0, data.Length);
                    _LastWrite = DateTime.Now;

                    // Wait for response
                    int maxTries = DetermineMaxTriesToReceiveTimeout();
                    for (int i = 0; i < maxTries; i++)
                    {
                        Thread.Sleep(100);
                        if (ns.DataAvailable)
                            break;
                    }

                    if (!ns.DataAvailable)
                        return ReportError("No response from scale!");

                    byte[] myReadBuffer = new byte[1024];
                    StringBuilder myCompleteMessage = new StringBuilder();
                    int numberOfBytesRead = 0;
                    do
                    {
                        numberOfBytesRead = ns.Read(myReadBuffer, 0, myReadBuffer.Length);
                        if (numberOfBytesRead > 0)
                            myCompleteMessage.AppendFormat("{0}", Encoding.ASCII.GetString(myReadBuffer, 0, numberOfBytesRead));
                    }
                    while (ns.DataAvailable);

                    string readResult = myCompleteMessage.ToString().Trim();

                    if (string.IsNullOrEmpty(readResult))
                        return ReportError("Empty response from scale!");

                    // Parse SICS response
                    var parseResult = ParseSICSResponse(readResult);
                    if (parseResult != null)
                    {
                        LastWeight.ValueT = Math.Abs(parseResult.Weight).ToString();
                        ActualValue.ValueT = parseResult.Weight;
                        ScaleStatus.ValueT = parseResult.Status;
                        WeightUnit.ValueT = parseResult.Unit;
                        AlibiWeight.ValueT = parseResult.Weight;
                        
                        // Clear any previous alarms if successful
                        if (parseResult.Status == "S")
                        {
                            CommAlarm.ValueT = PANotifyState.Off;
                        }
                        
                        return parseResult;
                    }
                    else
                        return ReportError("Failed to parse scale response: " + readResult);
                }
            }
            catch (Exception e)
            {
                return ReportError(e.Message);
            }
            finally
            {
                ClosePort();
            }
        }

        private SICSWeightResult ParseSICSResponse(string response)
        {
            if (string.IsNullOrEmpty(response))
                return null;

            // Remove any line terminators
            response = response.Trim('\r', '\n', ' ');

            // SICS response format: "S S    12.345 g" or "S I" or "S +" or "S -"
            var parts = response.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            
            if (parts.Length < 2 || parts[0] != "S")
                return null;

            string status = parts[1];
            double weight = -99999;
            string unit = "";

            switch (status)
            {
                case "S": // Stable weight
                    if (parts.Length >= 4)
                    {
                        if (double.TryParse(parts[2], out weight))
                        {
                            unit = parts[3];
                            NotStandStill.ValueT = false;
                        }
                    }
                    break;
                case "I": // Not stable / timeout
                    NotStandStill.ValueT = true;
                    return new SICSWeightResult(weight, status, unit, "Weight not stable or timeout");
                case "+": // Overcapacity
                    return new SICSWeightResult(weight, status, unit, "Scale in overcapacity range");
                case "-": // Undercapacity
                    return new SICSWeightResult(weight, status, unit, "Scale in undercapacity range");
                default:
                    return new SICSWeightResult(weight, status, unit, "Unknown status: " + status);
            }

            return new SICSWeightResult(weight, status, unit, null);
        }

        private int DetermineMaxTriesToReceiveTimeout()
        {
            if (ReceiveTimeout > 0)
            {
                var tries = ReceiveTimeout / 100;
                if (tries > 5)
                {
                    return tries;
                }
            }
            return 10;
        }

        protected SICSWeightResult ReportError(string error)
        {
            CommAlarm.ValueT = PANotifyState.AlarmOrFault;
            if (IsAlarmActive(nameof(CommAlarm), error) == null)
                Messages.LogException(GetACUrl(), "ReportError()", error);
            OnNewAlarmOccurred(CommAlarm, error, true);
            return new SICSWeightResult(-99999, "Error", "", error);
        }

        private SICSWeightResult SetZeroInternal()
        {
            // SICS command "Z" for zeroing
            return SendSICSCommand("Z", "Zero command");
        }

        private SICSWeightResult TareInternal()
        {
            // SICS command "T" for taring
            return SendSICSCommand("T", "Tare command");
        }

        private SICSWeightResult SendSICSCommand(string command, string description)
        {
            try
            {
                if (!IsConnected.ValueT)
                {
                    OpenPort();
                    if (TcpClient == null || !TcpClient.Connected)
                        return ReportError("Can not open TCP/IP-Port!");
                }

                using (ACMonitor.Lock(_61000_LockPort))
                {
                    NetworkStream ns = TcpClient.GetStream();
                    if (ns == null || !ns.CanWrite)
                    {
                        ClosePort();
                        return ReportError("Can not write to stream!");
                    }

                    if ((DateTime.Now - _LastWrite).TotalMilliseconds < 500)
                        Thread.Sleep(500);

                    string fullCommand = command + (CommandTerminator ?? "\r\n");
                    Byte[] data = Encoding.ASCII.GetBytes(fullCommand);
                    ns.Write(data, 0, data.Length);
                    _LastWrite = DateTime.Now;

                    // Wait for response
                    int maxTries = DetermineMaxTriesToReceiveTimeout();
                    for (int i = 0; i < maxTries; i++)
                    {
                        Thread.Sleep(100);
                        if (ns.DataAvailable)
                            break;
                    }

                    if (!ns.DataAvailable)
                        return ReportError($"No response from scale for {description}!");

                    byte[] myReadBuffer = new byte[1024];
                    StringBuilder myCompleteMessage = new StringBuilder();
                    int numberOfBytesRead = 0;
                    do
                    {
                        numberOfBytesRead = ns.Read(myReadBuffer, 0, myReadBuffer.Length);
                        if (numberOfBytesRead > 0)
                            myCompleteMessage.AppendFormat("{0}", Encoding.ASCII.GetString(myReadBuffer, 0, numberOfBytesRead));
                    }
                    while (ns.DataAvailable);

                    string readResult = myCompleteMessage.ToString().Trim();
                    
                    // For zero and tare commands, typically expect "Z A" or "T A" for acknowledge
                    var parts = readResult.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length >= 2 && parts[0] == command && parts[1] == "A")
                    {
                        return new SICSWeightResult(0, "A", "", null);
                    }
                    else
                    {
                        return ReportError($"{description} failed: {readResult}");
                    }
                }
            }
            catch (Exception e)
            {
                return ReportError($"{description} error: {e.Message}");
            }
            finally
            {
                ClosePort();
            }
        }

        #endregion
        #endregion

        protected override bool HandleExecuteACMethod(out object result, AsyncMethodInvocationMode invocationMode, string acMethodName, ACClassMethod acClassMethod, params object[] acParameter)
        {
            result = null;

            switch (acMethodName)
            {
                case nameof(ReadWeight):
                    result = ReadWeight();
                    return true;
                case nameof(IsEnabledReadWeightInt):
                    result = IsEnabledReadWeightInt();
                    return true;
                case nameof(OpenPort):
                    OpenPort();
                    return true;
                case nameof(ReadWeightInt):
                    ReadWeightInt();
                    return true;
                case nameof(IsEnabledOpenPort):
                    result = IsEnabledOpenPort();
                    return true;
                case nameof(ClosePort):
                    ClosePort();
                    return true;
                case nameof(IsEnabledClosePort):
                    result = IsEnabledClosePort();
                    return true;
                case nameof(StartReadWeightData):
                    StartReadWeightData();
                    return true;
                case nameof(IsEnabledStartReadWeightData):
                    result = IsEnabledStartReadWeightData();
                    return true;
                case nameof(StopReadWeightData):
                    StopReadWeightData();
                    return true;
                case nameof(IsEnabledStopReadWeightData):
                    result = IsEnabledStopReadWeightData();
                    return true;
            }

            return base.HandleExecuteACMethod(out result, invocationMode, acMethodName, acClassMethod, acParameter);
        }
    }

    /// <summary>
    /// Result class for SICS weight responses
    /// </summary>
    public class SICSWeightResult
    {
        public double Weight { get; set; }
        public string Status { get; set; }
        public string Unit { get; set; }
        public string ErrorMessage { get; set; }

        public SICSWeightResult(double weight, string status, string unit, string errorMessage)
        {
            Weight = weight;
            Status = status;
            Unit = unit;
            ErrorMessage = errorMessage;
        }

        public override string ToString()
        {
            if (!string.IsNullOrEmpty(ErrorMessage))
                return $"Error: {ErrorMessage}";
            
            return $"Weight: {Weight} {Unit}, Status: {Status}";
        }
    }
}