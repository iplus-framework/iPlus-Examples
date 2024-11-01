using gip.core.autocomponent;
using gip.core.datamodel;
using System;
using System.Collections.Generic;
using System.IO;

namespace mycompany.package.proc
{
    // 1. Use Global.ACKinds.TPAProcessFunction to publish the function to the iPlus-Type-System. Refer with PWOrder.PWClassName the dedicated Workflow-Class.  
    [ACClassInfo("mycompany.erp", "en{'Example Processfunction'}de{'Example Processfunction'}", Global.ACKinds.TPAProcessFunction, Global.ACStorableTypes.Required, false, PWOrder.PWClassName, true)]
    public class PAFOrder : PAProcessFunction
    {
        #region Constructors
        static PAFOrder()
        {
            // 2. Register a ACMethod-Template for this Function
            ACMethod method = new ACMethod("WriteOrder");
            Dictionary<string, string> paramTranslation = new Dictionary<string, string>();
            method.ParameterValueList.Add(new ACValue("Path", typeof(string), null, Global.ParamOption.Optional));
            paramTranslation.Add("Path", "en{'Path'}de{'Path'}");
            method.ParameterValueList.Add(new ACValue("FileName", typeof(string), null, Global.ParamOption.Optional));
            paramTranslation.Add("FileName", "en{'FileName'}de{'FileName'}");
            method.ParameterValueList.Add(new ACValue("Content", typeof(string), 0, Global.ParamOption.Required));
            paramTranslation.Add("Content", "en{'Content'}de{'Content'}");
            Dictionary<string, string> resultTranslation = new Dictionary<string, string>();
            method.ResultValueList.Add(new ACValue("Duration", typeof(double), 0.0, Global.ParamOption.Required));
            resultTranslation.Add("Duration", "en{'Duration[ms]'}de{'Duration[ms]'}");
            var wrapper = new ACMethodWrapper(method, "en{'Write order'}de{'Auftrag schreiben'}", typeof(PWOrder), paramTranslation, resultTranslation);
            ACMethod.RegisterVirtualMethod(typeof(PAFOrder), ACStateConst.TMStart, wrapper);

            // 3. Register static Method-Invocation-Handler for Client/Proxy-Side
            RegisterExecuteHandler(typeof(PAFOrder), HandleExecuteACMethod_PAFOrder);
        }

        public PAFOrder(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }
        #endregion 

        #region Public 

        #region Execute-Helper-Handlers
        public static bool HandleExecuteACMethod_PAFOrder(out object result, IACComponent acComponent, string acMethodName, gip.core.datamodel.ACClassMethod acClassMethod, params object[] acParameter)
        {
            return HandleExecuteACMethod_PAProcessFunction(out result, acComponent, acMethodName, acClassMethod, acParameter);
        }
        #endregion


        // 4. Override the Start-Method and use the ACMethodAsync-Attribute!
        [ACMethodAsync("Process", "en{'Start'}de{'Start'}", (short)MISort.Start, false)]
        public override ACMethodEventArgs Start(ACMethod acMethod)
        {
            return base.Start(acMethod);
        }

        int _WaitWithWriteCounter = 0;
        public override void SMIdle()
        {
            _WaitWithWriteCounter = 0;
            base.SMIdle();
        }

        public override void SMRunning()
        {
            // 5. The following conde is only an example to demonstrate how cyclic methods works
            if (_WaitWithWriteCounter < 3)
            {
                SubscribeToProjectWorkCycle();
                _WaitWithWriteCounter++;
                return;
            }
            UnSubscribeToProjectWorkCycle();

            // 6. To release the workload on the cyclic thread we recommmend to delegate your code to the ApplicationQueue:
            ApplicationManager.ApplicationQueue.Add(() =>
            {
                try
                {
                    string path = CurrentACMethod.ValueT.ParameterValueList.GetACValue("Path").ParamAsString;
                    string fileName = CurrentACMethod.ValueT.ParameterValueList.GetACValue("FileName").ParamAsString;
                    if (String.IsNullOrEmpty(path))
                        path = Path.GetTempPath();
                    if (String.IsNullOrEmpty(fileName))
                        fileName = String.Format("TestWrite{0:yyyy-MM-dd-HH-mm-ss}.txt", DateTime.Now);
                    File.WriteAllText(Path.Combine(path, fileName), CurrentACMethod.ValueT.ParameterValueList.GetACValue("Content").ParamAsString);
                }
                catch (Exception e)
                {
                    if (FunctionError.ValueT == PANotifyState.Off)
                        Messages.LogException(this.GetACUrl(), "SMRunning()", e);
                    FunctionError.ValueT = PANotifyState.AlarmOrFault;
                    OnNewAlarmOccurred(FunctionError, new Msg(e.Message, this, eMsgLevel.Exception, "PAFOrder", "SMRunning", 1000), true);
                }
            }
            );

            // 7. Switch to the next state by setting the ACState-Property
            // If a custom State-Converter was configured as a child:
            if (ACStateConverter != null)
                CurrentACState = ACStateConverter.GetNextACState(this);
            // Else return ACStateEnum.SMCompleted as the next default state by calling the static "default-method"
            else
                CurrentACState = PAFuncStateConvBase.GetDefaultNextACState(CurrentACState);
            _WaitWithWriteCounter = 0;
        }
        #endregion
    }
}
