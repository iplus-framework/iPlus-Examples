using gip.core.autocomponent;
using gip.core.datamodel;
using System;
using System.Collections.Generic;
using System.IO;

namespace mycompany.package.proc
{
    [ACClassInfo("mycompany.erp", "en{'Example Processmodule'}de{'Example Processmodule'}", Global.ACKinds.TPAProcessModule, Global.ACStorableTypes.Required, false, PWGroup.PWClassName, true)]
    public class PAMOrder : PAProcessModule
    {
        static PAMOrder()
        {
            RegisterExecuteHandler(typeof(PAMOrder), HandleExecuteACMethod_PAMOrder);
        }

        public PAMOrder(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
            _PAPointMatIn1 = new PAPoint(this, Const.PAPointMatIn1);
            _PAPointMatOut1 = new PAPoint(this, Const.PAPointMatOut1);
        }

        #region Points
        PAPoint _PAPointMatIn1;
        [ACPropertyConnectionPoint(9999, "PointMaterial")]
        public PAPoint PAPointMatIn1
        {
            get
            {
                return _PAPointMatIn1;
            }
        }

        PAPoint _PAPointMatOut1;
        [ACPropertyConnectionPoint(9999, "PointMaterial")]
        public PAPoint PAPointMatOut1
        {
            get
            {
                return _PAPointMatOut1;
            }
        }
        #endregion

        #region Alarms
        [ACPropertyBindingSource(210, "Error", "en{'My Alarm Property'}de{'Meine Alarmeigenschaft'}", "", false, false)]
        public IACContainerTNet<PANotifyState> IsMyAlarmActive { get; set; }

        public void RaiseAlarm(bool translated)
        {
            if (!translated)
            {
                string message = "Not translated messagetext";
                // With IsAlarmActive() you check if there is already an equal unacknowledged Alarm in the Alarm-Dictionary.
                // Equality means: The message-text is equal AND the internal Alarm-Dictionary has saved this message at the index where the ACIdentifier of the passed property is equal.
                // This helps to avoid writing the same error to the Logfile if this method is called cyclic in a thread.
                if (IsAlarmActive(IsMyAlarmActive, message) == null)
                {
                    // IsAlarmActive() has not returned a Msg-Instance 
                    // This means, that the same alarm is not in the internal Alarm-Dictionary => write the message to the logfile.
                    Messages.LogError(this.GetACUrl(), "RaiseAlarm(10)", message);
                }
                // Raise the new message. A new Msg-Entry is added to the internal Alarm-Dictionary.
                // If there is already an equal unacknowledged Alarm in the internal Alarm-Dictionary, than this same message will not be added twice!
                // Therefore you must not call IsAlarmActive() before if this method is called cyclic in a thread.
                OnNewAlarmOccurred(IsMyAlarmActive, message, true);

                // Optional: Set value of Alarm-Property to AlarmOrFault, if you want to signal it with the bound WPF-Control.
                IsMyAlarmActive.ValueT = PANotifyState.AlarmOrFault;
            }
            else
            {
                // Create a translated message.
                Msg msg = new Msg(this, eMsgLevel.Error, nameof(PAMOrder), "RaiseAlarm(20)", 20, "Error50476");
                if (IsAlarmActive(IsMyAlarmActive, msg.Message) == null)
                    Messages.LogError(this.GetACUrl(), msg.ACIdentifier, msg.Message);
                // Pass the complete msg-object and it's used as the new entry in the internal Alarm-Dictionary.
                // If there is already an equal unacknowledged Alarm in the internal Alarm-Dictionary, than this new msg-object will not be added twice!
                OnNewAlarmOccurred(IsMyAlarmActive, msg, true);
                IsMyAlarmActive.ValueT = PANotifyState.AlarmOrFault;
            }
        }

        public override void AcknowledgeAlarms()
        {
            if (!IsEnabledAcknowledgeAlarms())
                return;
            if (IsMyAlarmActive.ValueT == PANotifyState.AlarmOrFault)
            {
                base.AcknowledgeAlarms();
                // Reset the Alarm-State => The alarm disappears on the GUI or in the WPF-Control that is bound to this property.
                IsMyAlarmActive.ValueT = PANotifyState.Off;
                // Removes the Alarm from the internal Alarm-Dictionary.
                // This call is not necessary if you call base.AcknowledgeAlarms() before. AcknowledgeAlarms() Removes all Alarms from the Alarm-Dictionary.
                OnAlarmDisappeared(IsMyAlarmActive);
            }
        }

        [ACMethodInteraction("", "en{'Alarm 1'}de{'Alarm 1'}", 800, true, "")]
        public void AlarmTest1()
        {
            RaiseAlarm(false);
        }


        [ACMethodInteraction("", "en{'Alarm 2'}de{'Alarm 2'}", 801, true, "")]
        public void AlarmTest2()
        {
            RaiseAlarm(true);
        }
        #endregion

        #region Execute-Helper-Handlers
        protected override bool HandleExecuteACMethod(out object result, AsyncMethodInvocationMode invocationMode, string acMethodName, ACClassMethod acClassMethod, params object[] acParameter)
        {
            result = null;
            switch (acMethodName)
            {
                case nameof(AlarmTest1):
                    AlarmTest1();
                    return true;
                case nameof(AlarmTest2):
                    AlarmTest2();
                    return true;
            }
            return base.HandleExecuteACMethod(out result, invocationMode, acMethodName, acClassMethod, acParameter);
        }

        public static bool HandleExecuteACMethod_PAMOrder(out object result, IACComponent acComponent, string acMethodName, gip.core.datamodel.ACClassMethod acClassMethod, params object[] acParameter)
        {
            return HandleExecuteACMethod_PAProcessModule(out result, acComponent, acMethodName, acClassMethod, acParameter);
        }
        #endregion
    }
}
