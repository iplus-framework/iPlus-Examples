using gip.core.autocomponent;
using gip.core.datamodel;
using mycompany.package.datamodel;
using System.Collections.Generic;
using System;
using System.Linq;
using System.Text;
using System.Xml;
using Microsoft.EntityFrameworkCore;

namespace mycompany.package.proc
{
    // 1. Use Global.ACKinds.TPWNodeMethod to publish the Workflow-Class to the iPlus-Type-System.
    [ACClassInfo("mycompany.erp", "en{'Example WFNode'}de{'Example WFNode'}", Global.ACKinds.TPWNodeMethod, Global.ACStorableTypes.Optional, false, PWProcessFunction.PWClassName, true)]
    public class PWOrder : PWNodeProcessMethod
    {
        public const string PWClassName = "PWOrder";

        #region c´tors
        static PWOrder()
        {
            // 2. Register a ACMethod-Template for this Workflow-Class
            ACMethod method = new ACMethod(ACStateConst.SMStarting);
            Dictionary<string, string> paramTranslation = new Dictionary<string, string>();
            method.ParameterValueList.Add(new ACValue("SkipIfNoLines", typeof(bool), false, Global.ParamOption.Required));
            paramTranslation.Add("SkipIfNoLines", "en{'Skip if no lines'}de{'Überspringe wenn keine Positionen'}");
            var wrapper = new ACMethodWrapper(method, "en{'Configuration'}de{'Konfiguration'}", typeof(PWOrder), paramTranslation, null);
            ACMethod.RegisterVirtualMethod(typeof(PWOrder), ACStateConst.SMStarting, wrapper);

            // 3. Register static Method-Invocation-Handler for Client/Proxy-Side
            RegisterExecuteHandler(typeof(PWOrder), HandleExecuteACMethod_PWOrder);
        }

        public PWOrder(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }

        public override bool ACDeInit(bool deleteACClassTask = false)
        {
            // 15. Reset local members to make this instance reusable before it will be added to the component pool
            using (ACMonitor.Lock(_20015_LockValue))
            {
                _CountLines = 0;
            }
            return base.ACDeInit(deleteACClassTask);
        }

        public override void Recycle(IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
        {
            // 15. Reset local members to make this instance reusable when it was taken from the component pool
            using (ACMonitor.Lock(_20015_LockValue))
            {
                _CountLines = 0;
            }
            base.Recycle(content, parentACObject, parameter, acIdentifier);
        }

        #endregion


        #region Execute-Helper-Handlers
        public static bool HandleExecuteACMethod_PWOrder(out object result, IACComponent acComponent, string acMethodName, gip.core.datamodel.ACClassMethod acClassMethod, params object[] acParameter)
        {
            return HandleExecuteACMethod_PWNodeProcessMethod(out result, acComponent, acMethodName, acClassMethod, acParameter);
        }
        #endregion


        #region Properties
        // 16. The data context with which the class works is stored in the Root-Workflow-Node of class PWProcFuncOrder
        public InOrder CurrentInOrder
        {
            get
            {
                if (ParentRootWFNode == null)
                    return null;
                PWProcFuncOrder pWProcFunc = ParentRootWFNode as PWProcFuncOrder;
                if (pWProcFunc == null)
                    return null;
                return pWProcFunc.CurrentInOrder;
            }
        }

        // 12. Provide a Property for a easy access to the configured value in ParameterValueList
        protected bool SkipIfNoLines
        {
            get
            {
                var method = MyConfiguration;
                if (method != null)
                {
                    var acValue = method.ParameterValueList.GetACValue("SkipIfNoLines");
                    if (acValue != null)
                    {
                        return acValue.ParamAsBoolean;
                    }
                }
                return false;
            }
        }

        private int _CountLines = 0;
        // 13. Access private fields via ACMonitor.Lock()
        public int CountLines
        {
            get
            {
                using (ACMonitor.Lock(_20015_LockValue)) { return _CountLines; }
            }
        }
        #endregion


        #region Methods
        // 4. Override SMStarting and use the ACMethodState-Attribute!
        [ACMethodState("en{'Executing'}de{'Ausführend'}", 20, true)]
        public override void SMStarting()
        {
            string csv = GetOrderDataCSV();
            if (   String.IsNullOrEmpty(csv)
                || (CountLines <= 0 && SkipIfNoLines))
            {
                if (CurrentACState == ACStateEnum.SMStarting)
                    CurrentACState = ACStateEnum.SMCompleted;
                return;
            }

            if (ParentPWGroup != null && this.ContentACClassWF != null)
            {
                // 5. RefPAACClassMethod is a reference to the virtual "WriteOrder"-Method
                ACClassMethod refPAACClassMethod = null;
                using (ACMonitor.Lock(this.ContextLockForACClassWF))
                {
                    refPAACClassMethod = this.ContentACClassWF.RefPAACClassMethod;
                }

                if (refPAACClassMethod != null)
                {
                    PAProcessModule module = ParentPWGroup.AccessedProcessModule;
                    if (module == null)
                    {
                        Msg msg = new Msg("AccessedProcessModule is null", this, eMsgLevel.Error, PWClassName, "SMStarting", 1010);
                        if (IsAlarmActive(ProcessAlarm, msg.Message) == null)
                            Messages.LogError(this.GetACUrl(), "SMStarting(10)", msg.Message);
                        OnNewAlarmOccurred(ProcessAlarm, msg, true);
                        SubscribeToProjectWorkCycle();
                        return;
                    }

                    // 6. With TypeACSignature() you get ACMethod for "WriteOrder"
                    ACMethod paramMethod = refPAACClassMethod.TypeACSignature();
                    if (!(bool)ExecuteMethod("GetConfigForACMethod", paramMethod, true))
                        return;
                    // 7. Set all necessary parameters
                    paramMethod.ParameterValueList["Content"] = csv;

                    RecalcTimeInfo();
                    if (CreateNewProgramLog(paramMethod) <= CreateNewProgramLogResult.ErrorNoProgramFound)
                        return;
                    _ExecutingACMethod = paramMethod;

                    // 8. Start asynchronous task on PAFOrder.
                    if (!IsTaskStarted(module.TaskInvocationPoint.AddTask(paramMethod, this)))
                    {
                        SubscribeToProjectWorkCycle();
                        return;
                    }
                    else
                        UnSubscribeToProjectWorkCycle();
                    UpdateCurrentACMethod();
                }
            }

            // 9. Switch to State SMRunning
            // (If module.AddTask was exceuted syncronously then state is maybe already Runnning.)
            if (IsACStateMethodConsistent(ACStateEnum.SMStarting) < ACStateCompare.WrongACStateMethod)
                CurrentACState = ACStateEnum.SMRunning;
        }

        // Optional override: Handle the Function-Result
        public override void TaskCallback(IACPointNetBase sender, ACEventArgs e, IACObject wrapObject)
        {
            if (e != null)
            {
                IACTask taskEntry = wrapObject as IACTask;
                ACMethodEventArgs eM = e as ACMethodEventArgs;
                if (taskEntry.State == PointProcessingState.Deleted)
                { /* Task completed: Place here your code */
                }
                else if (   eM.ResultState == Global.ACMethodResultState.InProcess 
                         && taskEntry.State == PointProcessingState.Accepted)
                { /* Task running: Place here your code */
                }
                // Starting of a Method failed
                else if (taskEntry.State == PointProcessingState.Rejected)
                { /* Task rejected: Place here your code */
                }
            }
            base.TaskCallback(sender, e, wrapObject);
        }

        private string GetOrderDataCSV()
        {
            int countLines = 0;
            if (CurrentInOrder == null)
                return null;
            StringBuilder sb = new StringBuilder();
            // 17. Always access the data context with a new EF-Database-Instance because the Entities in the root workflow-node are in DETACHED-State! 
            using (MyCompanyDB dbApp = new MyCompanyDB())
            {
                InOrder inOrder = dbApp.InOrder.Include(c => c.InOrderPos_InOrder)
                                        .Include("InOrderPos_InOrder.Material")
                                        .Where(c => c.InOrderID == CurrentInOrder.InOrderID)
                                        .FirstOrDefault();
                if (inOrder != null)
                {
                    sb.AppendLine(String.Format("{0};{1};", inOrder.InOrderNo, inOrder.InOrderDate));
                    foreach (var line in inOrder.InOrderPos_InOrder)
                    {
                        countLines++;
                        sb.AppendLine(String.Format("{0};{1};", line.Material.MaterialNo, line.TargetQuantity));
                    }
                }
            }
            using (ACMonitor.Lock(_20015_LockValue)) { _CountLines = countLines; }

            return sb.ToString();
        }

        protected override void DumpPropertyList(XmlDocument doc, XmlElement xmlACPropertyList, ref DumpStats dumpStats)
        {
            base.DumpPropertyList(doc, xmlACPropertyList, ref dumpStats);
            // 14. Dump private fields for diagnostic
            XmlElement xmlChild = xmlACPropertyList["CountLines"];
            if (xmlChild == null)
            {
                xmlChild = doc.CreateElement("CountLines");
                if (xmlChild != null)
                    xmlChild.InnerText = CountLines.ToString();
                xmlACPropertyList.AppendChild(xmlChild);
            }
        }
        #endregion
    }
}
