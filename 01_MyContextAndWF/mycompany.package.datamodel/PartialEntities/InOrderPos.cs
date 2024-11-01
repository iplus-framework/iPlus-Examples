using gip.core.datamodel;
using System;
using System.Collections.Generic;
using Microsoft.EntityFrameworkCore;
using System.Data.SqlClient;
using System.Linq;
using System.Runtime.CompilerServices;
using System.ComponentModel.DataAnnotations.Schema;


namespace mycompany.package.datamodel
{
    [ACClassInfo("mycompany.erp", "en{'Purchase Order Line'}de{'Bestellposition'}", Global.ACKinds.TACDBA, Global.ACStorableTypes.NotStorable, false, true)]
    [ACPropertyEntity(1, "Sequence", "en{'Sequence'}de{'Folge'}", "", "", true)]
    [ACPropertyEntity(2, Material.ClassName, "en{'Material'}de{'Material'}", Const.ContextDatabase + "\\" + Material.ClassName, "", true)]
    [ACPropertyEntity(6, "TargetQuantity", "en{'Quantity'}de{'Menge'}", "", "", true)]
    [ACPropertyEntity(496, Const.EntityInsertDate, Const.EntityTransInsertDate)]
    [ACPropertyEntity(497, Const.EntityInsertName, Const.EntityTransInsertName)]
    [ACPropertyEntity(498, Const.EntityUpdateDate, Const.EntityTransUpdateDate)]
    [ACPropertyEntity(499, Const.EntityUpdateName, Const.EntityTransUpdateName)]
    [ACQueryInfoPrimary(Const.PackName_VarioPurchase, Const.QueryPrefix + InOrderPos.ClassName, "en{'Purchase Order Line'}de{'Bestellposition'}", typeof(InOrderPos), InOrderPos.ClassName, "Sequence", "Sequence")]
    [ACSerializeableInfo(new Type[] { typeof(ACRef<InOrderPos>) })]
    public partial class InOrderPos
    {
        public const string ClassName = "InOrderPos";

        #region New/Delete
        public static InOrderPos NewACObject(MyCompanyDB dbApp, IACObject parentACObject)
        {
            InOrderPos entity = new InOrderPos();
            entity.InOrderPosID = Guid.NewGuid();
            entity.DefaultValuesACObject();
            InOrder inOrder = parentACObject as InOrder;
            if (inOrder != null)
            {
                if (!inOrder.InOrderPos_InOrder_IsLoaded
                    && (inOrder.EntityState == EntityState.Modified || inOrder.EntityState == EntityState.Unchanged))
                    entity.Sequence = inOrder.Context.Entry(inOrder).Collection(c => c.InOrderPos_InOrder).Query().Max(c => c.Sequence) + 1;
                else if (inOrder.InOrderPos_InOrder.Any())
                {
                    IEnumerable<int> querySequence = inOrder.InOrderPos_InOrder.Select(c => c.Sequence);
                    entity.Sequence = querySequence.Any() ? querySequence.Max() + 1 : 1;
                }
                else
                    entity.Sequence = 1;

                entity.InOrder = inOrder;
                inOrder.InOrderPos_InOrder.Add(entity);
            }
            entity.SetInsertAndUpdateInfo(Database.Initials, dbApp);
            return entity;
        }

        /// <summary>
        /// Deletes this entity-object from the database
        /// </summary>
        /// <param name="database">Entity-Framework databasecontext</param>
        /// <param name="withCheck">If set to true, a validation happens before deleting this EF-object. If Validation fails message ís returned.</param>
        /// <param name="softDelete">If set to true a delete-Flag is set in the dabase-table instead of a physical deletion. If  a delete-Flag doesn't exit in the table the record will be deleted.</param>
        /// <returns>If a validation or deletion failed a message is returned. NULL if sucessful.</returns>
        public override MsgWithDetails DeleteACObject(IACEntityObjectContext database, bool withCheck, bool softDelete = false)
        {
            if (withCheck)
            {
                MsgWithDetails msg = IsEnabledDeleteACObject(database);
                if (msg != null)
                    return msg;
            }
            int sequence = Sequence;
            InOrder inOrder = InOrder;
            if (inOrder != null)
                if (inOrder.InOrderPos_InOrder_IsLoaded)
                    inOrder.InOrderPos_InOrder.Remove(this);
            database.Remove(this);
            if (inOrder != null)
                InOrderPos.RenumberSequence(inOrder, sequence);
            return null;
        }

        /// <summary>
        /// Handling von Sequencenummer ist nach dem Löschen aufzurufen
        /// </summary>
        public static void RenumberSequence(InOrder inOrder, int sequence)
        {
            if (inOrder == null
                || !inOrder.InOrderPos_InOrder.Any())
                return;

            var elements = inOrder.InOrderPos_InOrder.Where(c => c.Sequence > sequence && c.EntityState != EntityState.Deleted).OrderBy(c => c.Sequence);
            int sequenceCount = sequence;
            foreach (var element in elements)
            {
                element.Sequence = sequence;
                sequence++;
            }
        }
        #endregion

        #region IACUrl Member

        public override string ToString()
        {
            return InOrder?.InOrderNo + "/#" + Sequence.ToString() + "/" + Material?.ToString();
        }

        /// <summary>Translated Label/Description of this instance (depends on the current logon)</summary>
        /// <value>  Translated description</value>
        [ACPropertyInfo(9999)]
        [NotMapped]
        public override string ACCaption
        {
            get
            {
                if (Material == null)
                    return Sequence.ToString();
                return Sequence.ToString() + " " + Material.ACCaption;
            }
        }

        /// <summary>
        /// Returns InOrder
        /// NOT THREAD-SAFE USE QueryLock_1X000!
        /// </summary>
        /// <value>Reference to InOrder</value>
        [ACPropertyInfo(9999)]
        [NotMapped]
        public override IACObject ParentACObject
        {
            get
            {
                return InOrder;
            }
        }

        #endregion

        #region IACObjectEntity Members
        [NotMapped]
        static public string KeyACIdentifier
        {
            get
            {
                return "Sequence";
            }
        }
        #endregion
    }
}
