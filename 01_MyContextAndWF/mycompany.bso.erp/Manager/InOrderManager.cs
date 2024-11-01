using System;
using System.Data;
using System.Linq;
using gip.core.autocomponent;
using gip.core.datamodel;
using mycompany.package.datamodel;

namespace mycompany.bso.erp
{
    [ACClassInfo("mycompany.erp", "en{'Shared code for Purchase Orders'}de{'Gemeinsamer code für Bestellungen'}", Global.ACKinds.TPARole, Global.ACStorableTypes.NotStorable, false, false)]
    public class InOrderManager : PARole
    {
        #region c´tors
        public InOrderManager(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }
        public const string C_DefaultServiceACIdentifier = "InOrderManager";
        #endregion

        #region Static Methods        
        /// (A) If you use InOrderManager as a local service object
        public static InOrderManager GetServiceInstance(ACComponent requester)
        {
            return GetServiceInstance<InOrderManager>(requester, C_DefaultServiceACIdentifier, CreationBehaviour.OnlyLocal|CreationBehaviour.FirstOrDefault);
        }

        /// (C) If you use InOrderManager as a network service object
        public static ACComponent GetServiceInstanceNet(ACComponent requester)
        {
            return GetServiceInstance<ACComponent>(requester, C_DefaultServiceACIdentifier);
        }

        /// (B) If you use InOrderManager as a local service object
        public static ACRef<InOrderManager> ACRefToServiceInstance(ACComponent requester)
        {
            InOrderManager serviceInstance = GetServiceInstance(requester);
            if (serviceInstance != null)
                return new ACRef<InOrderManager>(serviceInstance, requester);
            return null;
        }

        /// (D) If you use InOrderManager as a network service object
        public static ACRef<ACComponent> ACRefToServiceInstanceNet(ACComponent requester)
        {
            ACComponent serviceInstance = GetServiceInstanceNet(requester);
            if (serviceInstance != null)
                return new ACRef<ACComponent>(serviceInstance, requester);
            return null;
        }
        #endregion

        #region Shared Code
        /// <summary>(E) Method for local usage when instance is configured as a local service object at "\LocalServiceObjects"</summary>
        public double SumLines(MyCompanyDB dbApp, InOrder inOrder)
        {
            double sumTargetQuantity = 0.0;
            foreach (InOrderPos line in inOrder.InOrderPos_InOrder)
            {
                Add(dbApp, line, ref sumTargetQuantity);
            }
            return sumTargetQuantity;
        }

        /// <summary>(F)  Method for remote usage when instance is configured as a network service object at e.g. "\Services"</summary>
        [ACMethodInfo("Function", "en{'Sum lines'}de{'Summiere Positionen'}", 200)]
        public double SumLinesByID(Guid inOrderID)
        {
            // Implement stateless: Never use MyCompanyDB in a private Field!
            using (MyCompanyDB dbApp = new MyCompanyDB())
            {
                double sumTargetQuantity = 0.0;
                foreach (InOrderPos line in dbApp.InOrderPos.Where(c => c.InOrderID == inOrderID))
                {
                    Add(dbApp, line, ref sumTargetQuantity);
                }
                return sumTargetQuantity;
            }
        }

        /// <summary>Implement stateless: Pass all necessary data instead using private fields. e.g. "sumTargetQuantity" is passed by reference</summary>
        private void Add(MyCompanyDB dbApp, InOrderPos line, ref double sumTargetQuantity)
        {
            sumTargetQuantity += line.TargetQuantity;
        }
        #endregion

        #region Helpers
        protected override bool HandleExecuteACMethod(out object result, AsyncMethodInvocationMode invocationMode, string acMethodName, gip.core.datamodel.ACClassMethod acClassMethod, params object[] acParameter)
        {
            result = null;
            switch (acMethodName)
            {
                case "SumLinesByID":
                    result = SumLinesByID((Guid) acParameter[0]);
                    return true;
            }
            return base.HandleExecuteACMethod(out result, invocationMode, acMethodName, acClassMethod, acParameter);
        }
        #endregion
    }
}
