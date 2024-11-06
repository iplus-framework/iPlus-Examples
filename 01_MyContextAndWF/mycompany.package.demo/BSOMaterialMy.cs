using gip.core.autocomponent;
using gip.core.datamodel;
using mycompany.bso.erp;
using mycompany.package.datamodel;
using System.Linq;

namespace mycompany.package.demo
{
    [ACClassInfo("mycompany.erp", "en{'Material my BSO'}de{'Material mein BSO'}", Global.ACKinds.TACBSO, Global.ACStorableTypes.NotStorable, true, true, Const.QueryPrefix + nameof(Material))]
    public class BSOMaterialMy : BSOMaterial
    {
        public BSOMaterialMy(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }

        private ACRef<IACComponent> _RefToComp = null;

        public override bool ACDeInit(bool deleteACClassTask = false)
        {
            if (_RefToComp != null)
            {
                _RefToComp.Detach();
                _RefToComp = null;
            }
            return base.ACDeInit(deleteACClassTask);
        }

        [ACMethodCommand("", "en{'My Method'}de{'Meine Methode'}", 100, true)]
        public void MyMethod()
        {
            if (_RefToComp == null)
            {
                IACComponent proxyComp = ACUrlCommand(@"\AppExample\MyDemoComp1") as IACComponent;
                if (proxyComp != null)
                    _RefToComp = new ACRef<IACComponent>(proxyComp, this);
            }

            if (_RefToComp != null && CurrentMaterial != null)
            {
                IACContainerT<int> myCounter = _RefToComp.ValueT.GetPropertyNet(nameof(MyDemoComp.MyCounter)) as IACContainerT<int>;
                if (myCounter != null)
                    CurrentMaterial.MaterialName1 = string.Format("Current value: {0}", myCounter.ValueT);
            }
        }
    }
}
