using gip.core.autocomponent;
using gip.core.datamodel;
using gip.core.processapplication;
using System;
using System.Collections.Generic;
using System.IO;

namespace mycompany.package.proc
{
    [ACClassInfo("mycompany.erp", "en{'Motor Example'}de{'Motor Beispiel'}", Global.ACKinds.TPAModule, Global.ACStorableTypes.Required, false, true)]
    public class PAEMotorEx : PAEEMotor1D
    {
        static PAEMotorEx()
        {
            RegisterExecuteHandler(typeof(PAEMotorEx), HandleExecuteACMethod_PAEMotorEx);
        }

        public PAEMotorEx(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }

        #region Properties
        [ACPropertyBindingTarget(800, "", "en{'Extedented Property 1'}de{'Erweiterungs Eigenschaft 1'}", "", true, false)]
        public IACContainerTNet<int> MyExtProp { get; set; }
        #endregion

        #region Methods
        [ACMethodInteraction("", "en{'Increase Property'}de{'Erhöhe Eigenschaft'}", 800, true, "", Global.ACKinds.MSMethodPrePost)]
        public void IncreaseMyExtProp()
        {
            if (!IsEnabledIncreaseMyExtProp())
                return;
            MyExtProp.ValueT++;
        }

        public virtual bool IsEnabledIncreaseMyExtProp()
        {
            return true;
        }

        #endregion

        #region Execute-Helper-Handlers
        protected override bool HandleExecuteACMethod(out object result, AsyncMethodInvocationMode invocationMode, string acMethodName, ACClassMethod acClassMethod, params object[] acParameter)
        {
            result = null;
            switch (acMethodName)
            {
                case nameof(IncreaseMyExtProp):
                    IncreaseMyExtProp();
                    return true;
                case Const.IsEnabledPrefix + nameof(IncreaseMyExtProp):
                    result = IsEnabledIncreaseMyExtProp();
                    return true;
            }
            return base.HandleExecuteACMethod(out result, invocationMode, acMethodName, acClassMethod, acParameter);
        }

        public static bool HandleExecuteACMethod_PAEMotorEx(out object result, IACComponent acComponent, string acMethodName, gip.core.datamodel.ACClassMethod acClassMethod, params object[] acParameter)
        {
            return HandleExecuteACMethod_PAEEMotor1D(out result, acComponent, acMethodName, acClassMethod, acParameter);
        }
        #endregion
    }
}
