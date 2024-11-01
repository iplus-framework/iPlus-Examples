using gip.core.datamodel;
using System;
using System.Linq;
using Microsoft.EntityFrameworkCore;
using System.Runtime.CompilerServices;
using System.ComponentModel.DataAnnotations.Schema;

namespace mycompany.package.datamodel
{
    [ACClassInfo("mycompany.erp", "en{'Material'}de{'Material'}", Global.ACKinds.TACDBA, Global.ACStorableTypes.NotStorable, false, true, "", "BSOMaterial")]
    [ACPropertyEntity(1, "MaterialNo", "en{'Material No.'}de{'Material-Nr.'}", "", "", true, MinLength = 1, MaxLength = 30)]
    [ACPropertyEntity(2, "MaterialName1", "en{'Material Desc. 1'}de{'Materialbez. 1'}", "", "", true, MaxLength = 40)]
    [ACPropertyEntity(496, Const.EntityInsertDate, Const.EntityTransInsertDate)]
    [ACPropertyEntity(497, Const.EntityInsertName, Const.EntityTransInsertName)]
    [ACPropertyEntity(498, Const.EntityUpdateDate, Const.EntityTransUpdateDate)]
    [ACPropertyEntity(499, Const.EntityUpdateName, Const.EntityTransUpdateName)]
    [ACQueryInfoPrimary(Const.PackName_VarioMaterial, Const.QueryPrefix + Material.ClassName, "en{'Material'}de{'Material'}", 
                        typeof(Material), Material.ClassName, "MaterialNo,MaterialName1", "MaterialNo")]
    [ACSerializeableInfo(new Type[] { typeof(ACRef<Material>) })]
    public partial class Material
    {
        public const string ClassName = "Material";
        public readonly ACMonitorObject _10020_LockValue = new ACMonitorObject(10020);

        #region New/Delete
        public static Material NewACObject(MyCompanyDB dbApp, IACObject parentACObject)
        {
            Material entity = new Material();
            entity.MaterialID = Guid.NewGuid();
            entity.DefaultValuesACObject();
            entity.SetInsertAndUpdateInfo(Database.Initials, dbApp);
            return entity;
        }

        #endregion


        #region IACObject Member
        public override string ToString()
        {
            return MaterialNo + "/" + MaterialName1;
        }

        [ACPropertyInfo(9999)]
        public override string ACCaption
        {
            get
            {
                return MaterialNo + " " + MaterialName1;
            }
        }

        /// <summary>
        /// Returns a related EF-Object which is in a Child-Relationship to this.
        /// </summary>
        /// <param name="className">Classname of the Table/EF-Object</param>
        /// <param name="filterValues">Search-Parameters</param>
        /// <returns>A Entity-Object as IACObject</returns>
        public override IACObject GetChildEntityObject(string className, params string[] filterValues)
        {
            return null;
        }

        #endregion


        #region IACObjectEntity Members
        /// <summary>
        /// Gets the key AC identifier.
        /// </summary>
        /// <value>The key AC identifier.</value>
        [NotMapped]
        static public string KeyACIdentifier
        {
            get
            {
                return "MaterialNo";
            }
        }
        #endregion
    }
}
