using gip.core.autocomponent;
using gip.core.datamodel;
using System;
using mycompany.package.datamodel;
using System.Linq;

namespace mycompany.package.proc
{
    // 2. Declare the required paramters for instantianting this workflow class.
    // ACProgram.ClassName is obligatory. InOrder.ClassName is the data context for all this an all child workflow-nodes.
    [ACClassConstructorInfo(
    new object[]
        {
            new object[] {ACProgram.ClassName, Global.ParamOption.Required, typeof(Guid)},
            new object[] {ACProgramLog.ClassName, Global.ParamOption.Optional, typeof(Guid)},
            new object[] {PWProcessFunction.C_InvocationCount, Global.ParamOption.Optional, typeof(int)},
            new object[] {InOrder.ClassName, Global.ParamOption.Required, typeof(Guid)}
       }
    )]
    // 1. Use Global.ACKinds.TPWMethod to publish the Workflow-Class to the iPlus-Type-System.
    [ACClassInfo("mycompany.erp", "en{'Example WFRoot'}de{'Example WFRoot'}", Global.ACKinds.TPWMethod, Global.ACStorableTypes.Required, true, true, "", "", 10)]
    public class PWProcFuncOrder : PWProcessFunction
    {
        new public const string PWClassName = "PWProcFuncOrder";

        #region c´tors

        static PWProcFuncOrder()
        {
            // 3. Register static Method-Invocation-Handler for Client/Proxy-Side
            RegisterExecuteHandler(typeof(PWProcFuncOrder), HandleExecuteACMethod_PWProcFuncOrder);
        }

        public PWProcFuncOrder(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }

        public override bool ACDeInit(bool deleteACClassTask = false)
        {
            // 9. Reset local members to make this instance reusable before it will be added to the component pool
            using (ACMonitor.Lock(_20015_LockValue))
            {
                _CurrentInOrder = null;
            }

            if (!base.ACDeInit(deleteACClassTask))
                return false;

            return true;
        }

        public override void Recycle(IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
        {
            // 9. Reset local members to make this instance reusable when it was taken from the component pool
            using (ACMonitor.Lock(_20015_LockValue))
            {
                _CurrentInOrder = null;
            }
            base.Recycle(content, parentACObject, parameter, acIdentifier);
        }
        #endregion

        #region Properties

        private InOrder _CurrentInOrder = null;
        public InOrder CurrentInOrder
        {
            get
            {
                using (ACMonitor.Lock(_20015_LockValue))
                {
                    if (_CurrentInOrder != null)
                        return _CurrentInOrder;
                }
                LoadEntities();

                using (ACMonitor.Lock(_20015_LockValue))
                {
                    return _CurrentInOrder;
                }
            }
        }

        #endregion


        #region Methods

        #region overrides
        public override PAOrderInfo GetPAOrderInfo()
        {
            PAOrderInfo orderInfo = base.GetPAOrderInfo();

            if (CurrentInOrder == null)
                return orderInfo;

            if (orderInfo == null)
                orderInfo = new PAOrderInfo();

            orderInfo.Add(InOrder.ClassName, CurrentInOrder.InOrderID);

            return orderInfo;
        }

        #endregion


        #region Execute-Helper-Handlers
        protected override bool HandleExecuteACMethod(out object result, AsyncMethodInvocationMode invocationMode, string acMethodName, gip.core.datamodel.ACClassMethod acClassMethod, params object[] acParameter)
        {
            //result = null;
            //switch (acMethodName)
            //{
            //}
            return base.HandleExecuteACMethod(out result, invocationMode, acMethodName, acClassMethod, acParameter);
        }

        public static bool HandleExecuteACMethod_PWProcFuncOrder(out object result, IACComponent acComponent, string acMethodName, gip.core.datamodel.ACClassMethod acClassMethod, params object[] acParameter)
        {
            //result = null;
            //switch (acMethodName)
            //{
            //}
            return HandleExecuteACMethod_PWProcessFunction(out result, acComponent, acMethodName, acClassMethod, acParameter);
        }

        #endregion


        #region Logic
        // 4. Override the Start-Method
        public override ACMethodEventArgs Start(ACMethod acMethod)
        {
            // 5. Read the data context:
            InOrder inOrder = GetInOrder(acMethod);
            if (inOrder == null)
                return CreateNewMethodEventArgs(acMethod, Global.ACMethodResultState.Failed);
            using (ACMonitor.Lock(_20015_LockValue))
            {
                _CurrentInOrder = inOrder;
            }
            // 6. Call base-Start() to start the Workflow
            return base.Start(acMethod);
        }

        // 7. Override this method to control if Start-Node (PWNodeStart) can be activated to run the workflow 
        protected override bool CanRunWorkflow()
        {
            bool canRunWF = false;
            using (ACMonitor.Lock(_20015_LockValue))
            {
                canRunWF = _CurrentInOrder != null;
            }
            if (!canRunWF)
                return false;

            return ProcessAlarm.ValueT == PANotifyState.Off;
        }

        // 8. Method that reads the data context when iPlus-Service was restarted
        protected virtual void LoadEntities()
        {
            var rootPW = RootPW;
            if (   rootPW == null 
                || CurrentACMethod == null 
                || CurrentACMethod.ValueT == null)
                return;
            InOrder inOrder = GetInOrder(CurrentACMethod.ValueT);
            using (ACMonitor.Lock(_20015_LockValue))
            {
                _CurrentInOrder = inOrder;
            }
        }

        protected InOrder GetInOrder(ACMethod acMethod)
        {
            if (acMethod == null)
                return null;
            Guid inOrderID = (Guid)acMethod[InOrder.ClassName];
            if (inOrderID == Guid.Empty)
                return null;

            using (MyCompanyDB dbApp = new MyCompanyDB())
            {
                return dbApp.InOrder.Where(c => c.InOrderID == inOrderID)
                                        .SetMergeOption(MergeOption.NoTracking)
                                        .FirstOrDefault();
            }
        }
        #endregion

        #endregion

    }
}
