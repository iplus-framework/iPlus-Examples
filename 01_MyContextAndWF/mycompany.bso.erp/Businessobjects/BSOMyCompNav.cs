using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using gip.core.autocomponent;
using gip.core.datamodel;
using mycompany.package.datamodel;

namespace mycompany.bso.erp
{
    public abstract class BSOMyCompNav : ACBSONav
    {
        #region c´tors
        public BSOMyCompNav(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "") :
            base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }

        public override bool ACDeInit(bool deleteACClassTask = false)
        {
            bool result = base.ACDeInit(deleteACClassTask);
            _DatabaseApp = null;
            return result;
        }
        #endregion

        #region abstract member
        #region Database
        private MyCompanyDB _DatabaseApp = null;
        /// <summary>Returns the shared Database-App-Context for BSO's by calling GetAppContextForBSO()</summary>
        /// <value>Returns the shared Database-Context.</value>
        public virtual MyCompanyDB DatabaseApp
        {
            get
            {
                if (_DatabaseApp == null && this.InitState != ACInitState.Destructed && this.InitState != ACInitState.Destructing && this.InitState != ACInitState.DisposedToPool && this.InitState != ACInitState.DisposingToPool)
                    _DatabaseApp = GetAppContextForBSO(this);
                return _DatabaseApp as MyCompanyDB;
            }
        }

        /// <summary>
        /// Overriden: Returns the MyCompanyDB-Property.
        /// </summary>
        /// <value>The context as IACEntityObjectContext.</value>
        public override IACEntityObjectContext Database
        {
            get
            {
                return DatabaseApp;
            }
        }

        public static MyCompanyDB GetAppContextForBSO(ACComponent bso)
        {
            if (bso.ParentACComponent != null && bso.ParentACComponent.Database != null && bso.ParentACComponent.Database is MyCompanyDB)
                return bso.ParentACComponent.Database as MyCompanyDB;
            MyCompanyDB dbApp = ACObjectContextManager.GetContext("BSOMyCompContext") as MyCompanyDB;
            if (dbApp == null)
            {
                Database parentIPlusContext = new Database();
                dbApp = ACObjectContextManager.GetOrCreateContext<MyCompanyDB>("BSOMyCompContext", null, parentIPlusContext);
            }
            return dbApp;
        }
        #endregion
        #endregion

    }
}
