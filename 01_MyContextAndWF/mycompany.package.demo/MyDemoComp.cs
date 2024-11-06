using gip.core.autocomponent;
using gip.core.datamodel;
using mycompany.package.datamodel;
using System.Linq;

namespace mycompany.package.demo
{
    [ACClassInfo("mycompany.erp", "en{'My example component'}de{'Meine Beispielkomponente'}", Global.ACKinds.TPAModule, Global.ACStorableTypes.Required, false, true)]
    public class MyDemoComp : PAClassAlarmingBase
    {
        public MyDemoComp(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }

        [ACPropertyBindingTarget(100, "", "en{'My Counter'}de{'Mein Zähler'}", "", true, false)]
        public IACContainerTNet<int> MyCounter { get; set; }
        
        [ACPropertyBindingTarget(101, "", "en{'Odd'}de{'Ungerade'}", "", true, false)]
        public IACContainerTNet<bool> MyIsOdd { get; set; }

        #region Method
        [ACMethodInteraction("", "en{'Increase'}de{'Erhöhe'}", 100, true)]
        public void MyMethod()
        {
            MyCounter.ValueT++;
            MyIsOdd.ValueT = MyCounter.ValueT % 2 != 0;
            using (var db = new MyCompanyDB())
            {
                var mat = db.Material.Where(c => c.MaterialNo.Contains(MyCounter.ValueT.ToString())).FirstOrDefault();
                if (mat != null)
                    mat.MaterialName1 = "Found";
            }
        }

        public bool IsEnabledMyMethod()
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
                case nameof(MyMethod):
                    MyMethod();
                    return true;
                case nameof(IsEnabledMyMethod):
                    result = IsEnabledMyMethod();
                    return true;
            }
            return base.HandleExecuteACMethod(out result, invocationMode, acMethodName, acClassMethod, acParameter);
        }
        #endregion
    }
}
