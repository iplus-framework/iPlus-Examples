using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using System.Windows;
using System.Windows.Documents;
using gip.core.autocomponent;
using gip.core.datamodel;
using mycompany.package.datamodel;
using Microsoft.EntityFrameworkCore;

namespace mycompany.bso.erp
{
    [ACClassInfo("mycompany.erp", "en{'Purchase Order'}de{'Bestellung'}", Global.ACKinds.TACBSO, Global.ACStorableTypes.NotStorable, true, true, Const.QueryPrefix + nameof(InOrder))]
    public class BSOInOrder : BSOMyCompNav
    {
        #region c´tors

        public BSOInOrder(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }

        public override bool ACInit(Global.ACStartTypes startChildMode = Global.ACStartTypes.Automatic)
        {
            if (!base.ACInit(startChildMode))
                return false;
            // If you use InOrderManager as a local service object:
            _InOrderManager = InOrderManager.ACRefToServiceInstance(this);
            // If you use InOrderManager as a network service, than you have to retrieve a instance as ACComponent instead of InOrderManager,
            // because on client side you have only a proxy object (ACComponentProxy):
            _InOrderManagerNet = InOrderManager.ACRefToServiceInstanceNet(this);
            Search();
            return true;
        }

        public override bool ACDeInit(bool deleteACClassTask = false)
        {
            // Detach references
            if (_InOrderManager != null)
                InOrderManager.DetachACRefFromServiceInstance(this, _InOrderManager);
            _InOrderManager = null;
            if (_InOrderManagerNet != null)
                InOrderManager.DetachACRefFromServiceInstance(this, _InOrderManagerNet);
            _InOrderManagerNet = null;

            this._CurrentInOrderPos = null;
            this._SelectedInOrderPos = null;
            if (_AccessPrimary != null)
                _AccessPrimary.NavSearchExecuting -= _AccessPrimary_NavSearchExecuting;

            bool result = base.ACDeInit(deleteACClassTask);
            if (_AccessPrimary != null)
            {
                _AccessPrimary.ACDeInit(false);
                _AccessPrimary = null;
            }
            return result;
        }
        #endregion


        #region Properties

        #region 1. InOrder
        public override IAccessNav AccessNav { get { return AccessPrimary; } }
        ACAccessNav<InOrder> _AccessPrimary;
        [ACPropertyAccessPrimary(9999, nameof(InOrder))]
        public ACAccessNav<InOrder> AccessPrimary
        {
            get
            {
                if (_AccessPrimary == null && ACType != null)
                {
                    ACQueryDefinition acQueryDef = Root.Queries.CreateQueryByClass(null, PrimaryNavigationquery(), ACType.ACIdentifier);
                    if (acQueryDef != null)
                    {
                        ACSortItem sortItem = acQueryDef.ACSortColumns.Where(c => c.ACIdentifier == "InOrderNo").FirstOrDefault();
                        if (sortItem != null && sortItem.IsConfiguration)
                            sortItem.SortDirection = Global.SortDirections.descending;
                    }
                    _AccessPrimary = acQueryDef.NewAccessNav<InOrder>(nameof(InOrder), this);
                    _AccessPrimary.NavSearchExecuting += _AccessPrimary_NavSearchExecuting;
                }
                return _AccessPrimary;
            }
        }

        private IQueryable<InOrder> _AccessPrimary_NavSearchExecuting(IQueryable<InOrder> result)
        {
            result.Where(c => c.InOrderDate < DateTime.Now);
            IQueryable<InOrder> query = result as IQueryable<InOrder>;
            if (query != null)
                query.Include(c => c.InOrderPos_InOrder);
            return query;
        }

        [ACPropertyList(300, nameof(InOrder), "en{'Purchase Order Lisat'}de{'Bestellliste'}")]
        public IEnumerable<InOrder> InOrderList
        {
            get
            {
                return AccessPrimary.NavList;
            }
        }

        [ACPropertyCurrent(301, nameof(InOrder), "en{'Purchase Order'}de{'Bestellung'}")]
        public InOrder CurrentInOrder
        {
            get
            {
                if (AccessPrimary == null)
                    return null;
                return AccessPrimary.Current;
            }
            set
            {
                if (AccessPrimary == null)
                    return;
                AccessPrimary.Current = value;
                CurrentInOrderPos = null;
                OnPropertyChanged("CurrentInOrder");
                OnPropertyChanged("InOrderPosList");
            }
        }

        [ACPropertySelected(302, nameof(InOrder), "en{'Purchase Order'}de{'Bestellung'}")]
        public InOrder SelectedInOrder
        {
            get
            {
                if (AccessPrimary == null)
                    return null;
                return AccessPrimary.Selected;
            }
            set
            {
                if (AccessPrimary == null)
                    return;
                AccessPrimary.Selected = value;
                OnPropertyChanged("SelectedInOrder");
            }
        }
        #endregion

        #region 1.1 InOrderPos
        InOrderPos _CurrentInOrderPos;
        [ACPropertyCurrent(310, InOrderPos.ClassName, "en{'Purchase Order Line'}de{'Bestellposition'}")]
        public InOrderPos CurrentInOrderPos
        {
            get
            {
                return _CurrentInOrderPos;
            }
            set
            {
                if (_CurrentInOrderPos != null)
                    _CurrentInOrderPos.PropertyChanged -= CurrentInOrderPos_PropertyChanged;
                _CurrentInOrderPos = value;
                if (_CurrentInOrderPos != null)
                    _CurrentInOrderPos.PropertyChanged += CurrentInOrderPos_PropertyChanged;
                OnPropertyChanged("CurrentInOrderPos");
            }
        }

        void CurrentInOrderPos_PropertyChanged(object sender, System.ComponentModel.PropertyChangedEventArgs e)
        {
            switch (e.PropertyName)
            {
                case "MaterialID":
                    {
                        OnPropertyChanged("CurrentInOrderPos");
                    }
                    break;
            }
        }

        [ACPropertyList(312, InOrderPos.ClassName, "en{'Purchase Order Line List'}de{'Bestellpositionsliste'}")]
        public IEnumerable<InOrderPos> InOrderPosList
        {
            get
            {
                if (CurrentInOrder == null)
                    return null;
                return CurrentInOrder.InOrderPos_InOrder;
            }
        }

        InOrderPos _SelectedInOrderPos;
        [ACPropertySelected(311, InOrderPos.ClassName, "en{'Purchase Order Line'}de{'Bestellposition'}")]
        public InOrderPos SelectedInOrderPos
        {
            get
            {
                return _SelectedInOrderPos;
            }
            set
            {
                _SelectedInOrderPos = value;
                OnPropertyChanged("SelectedInOrderPos");
            }
        }
        #endregion

        #region Printing
        public string PrintPropExample
        {
            get;set;
        }
        #endregion

        #region Services
        protected ACRef<InOrderManager> _InOrderManager = null;
        public InOrderManager InOrderManager
        {
            get
            {
                if (_InOrderManager == null)
                    return null;
                return _InOrderManager.ValueT;
            }
        }

        protected ACRef<ACComponent> _InOrderManagerNet = null;
        public ACComponent InOrderManagerNet
        {
            get
            {
                if (_InOrderManagerNet == null)
                    return null;
                return _InOrderManagerNet.ValueT;
            }
        }
        #endregion
        #endregion


        #region Methods

        #region Head
        [ACMethodCommand(nameof(InOrder), "en{'Save'}de{'Speichern'}", (short)MISort.Save, false, Global.ACKinds.MSMethodPrePost)]
        public void Save()
        {
            OnSave();
        }

        public bool IsEnabledSave()
        {
            return OnIsEnabledSave();
        }

        [ACMethodCommand(nameof(InOrder), "en{'Undo'}de{'Nicht speichern'}", (short)MISort.UndoSave, false, Global.ACKinds.MSMethodPrePost)]
        public void UndoSave()
        {
            OnUndoSave();
        }

        public bool IsEnabledUndoSave()
        {
            return OnIsEnabledUndoSave();
        }

        [ACMethodInteraction(nameof(InOrder), "en{'Load'}de{'Laden'}", (short)MISort.Load, false, "SelectedInOrder", Global.ACKinds.MSMethodPrePost)]
        public void Load(bool requery = false)
        {
            if (!PreExecute("Load"))
                return;
            LoadEntity<InOrder>(requery, () => SelectedInOrder, () => CurrentInOrder, c => CurrentInOrder = c,
                        DatabaseApp.InOrder
                        .Include(c => c.InOrderPos_InOrder)
                        .Where(c => c.InOrderID == SelectedInOrder.InOrderID));
            PostExecute("Load");
        }

        public bool IsEnabledLoad()
        {
            return SelectedInOrder != null;
        }

        [ACMethodInteraction(nameof(InOrder), "en{'New'}de{'Neu'}", (short)MISort.New, true, "SelectedInOrder", Global.ACKinds.MSMethodPrePost)]
        public void New()
        {
            string secondaryKey = Root.NoManager.GetNewNo(Database, typeof(InOrder), InOrder.NoColumnName, InOrder.FormatNewNo, this);
            CurrentInOrder = InOrder.NewACObject(DatabaseApp, null, secondaryKey);
            DatabaseApp.InOrder.Add(CurrentInOrder);
            SelectedInOrder = CurrentInOrder;
            if (AccessPrimary != null)
                AccessPrimary.NavList.Add(CurrentInOrder);
        }

        public bool IsEnabledNew()
        {
            return true;
        }

        [ACMethodInteraction(nameof(InOrder), "en{'Delete'}de{'Löschen'}", (short)MISort.Delete, true, "CurrentInOrder", Global.ACKinds.MSMethodPrePost)]
        public void Delete()
        {
            Msg msg = CurrentInOrder.DeleteACObject(DatabaseApp, true);
            if (msg != null)
            {
                Messages.Msg(msg);
                return;
            }
            if (AccessPrimary == null)
                return;
            AccessPrimary.NavList.Remove(CurrentInOrder);
            SelectedInOrder = AccessPrimary.NavList.FirstOrDefault();
            Load();
        }

        public bool IsEnabledDelete()
        {
            return CurrentInOrder != null;
        }

        [ACMethodCommand(nameof(InOrder), "en{'Search'}de{'Suchen'}", (short)MISort.Search)]
        public void Search()
        {
            if (AccessPrimary == null)
                return;
            AccessPrimary.NavSearch(DatabaseApp);
            OnPropertyChanged("InOrderList");
        }
        #endregion


        #region Lines

        [ACMethodInteraction(InOrderPos.ClassName, "en{'New Item'}de{'Neue Position'}", (short)MISort.New, true, "SelectedInOrderPos", Global.ACKinds.MSMethodPrePost)]
        public void NewInOrderPos()
        {
            var inOrderPos = InOrderPos.NewACObject(DatabaseApp, CurrentInOrder);
            CurrentInOrderPos = inOrderPos;
            SelectedInOrderPos = inOrderPos;
        }

        public bool IsEnabledNewInOrderPos()
        {
            return true;
        }

        [ACMethodInteraction(InOrderPos.ClassName, "en{'Delete Item'}de{'Position löschen'}", (short)MISort.Delete, true, "CurrentInOrderPos", Global.ACKinds.MSMethodPrePost)]
        public void DeleteInOrderPos()
        {
            Msg msg = CurrentInOrderPos.DeleteACObject(DatabaseApp, true);
            if (msg != null)
            {
                Messages.Msg(msg);
                return;
            }
            OnPropertyChanged("InOrderPosList");
        }

        public bool IsEnabledDeleteInOrderPos()
        {
            return CurrentInOrder != null && CurrentInOrderPos != null;
        }

        [ACMethodCommand("Sum", "en{'Sum lines'}de{'Summe Positionen'}", 200)]
        public void DisplaySum()
        {
            if (InOrderManager != null)
            {
                // Usage if InOrderManager is configured as local service object
                double sum = InOrderManager.SumLines(this.DatabaseApp, this.CurrentInOrder);
                Messages.Info(this, String.Format("Local invocation: Sum is {0}", sum), true);
            }

            if (InOrderManagerNet != null)
            {
                // Usage if InOrderManager is a network service
                object netResult = InOrderManagerNet.ACUrlCommand("!SumLinesByID", this.CurrentInOrder.InOrderID);
                if (netResult != null)
                    Messages.Info(this, String.Format("Remote invocation: Sum is {0}", (double)netResult), true);
            }
        }

        [ACMethodCommand("", "en{'Start Example-Workflow'}de{'Starte Beispiel-Workflow'}", 210)]
        public void StartExampleWorkflow()
        {
            if (!IsEnabledStartExampleWorkflow())
                return;
            ACComponent appRoot = ACUrlCommand("\\AppExample") as ACComponent;
            if (appRoot == null)
                return;
            if (appRoot.ConnectionState == ACObjectConnectionState.DisConnected)
                return;
            string methodName;
            // 1. Find Workflow-Method
            ACClassMethod acClassMethod = appRoot.GetACClassMethod("ExampleWorkflow", out methodName);
            if (acClassMethod == null)
                return;
            // 2. Create a new Instance of the virtual Method (ACMethod)
            ACMethod acMethod = appRoot.NewACMethod(methodName);
            if (acMethod == null)
                return;
            ACValue paramProgram = acMethod.ParameterValueList.GetACValue(ACProgram.ClassName);
            ACValue paramInOrder = acMethod.ParameterValueList.GetACValue(nameof(InOrder));
            if (paramProgram == null || paramInOrder == null)
                return;

            using (Database iPlusDB = new Database())
            {
                // 3. Switch database context
                acClassMethod = acClassMethod.FromIPlusContext<ACClassMethod>(iPlusDB);
                // 4. Create a new ACProgram-Instance and set the ProgramACClassMethod and WorkflowTypeACClass-Properties.
                string secondaryKey = Root.NoManager.GetNewNo(iPlusDB, typeof(ACProgram), ACProgram.NoColumnName, ACProgram.FormatNewNo, this);
                ACProgram program = ACProgram.NewACObject(iPlusDB, null, secondaryKey);
                program.ProgramACClassMethod = acClassMethod;
                program.WorkflowTypeACClass = acClassMethod.WorkflowTypeACClass;
                // 5. Save the ACProgram-Instance to the dabase first:
                iPlusDB.ACProgram.Add(program);
                if (iPlusDB.ACSaveChanges() == null)
                {
                    // 6. If ACProgram was sucessfully added to the database, start the workflow:
                    paramProgram.Value = program.ACProgramID;
                    paramInOrder.Value = CurrentInOrder.InOrderID;
                    appRoot.ExecuteMethod(acClassMethod.ACIdentifier, acMethod);
                }
            }
        }

        public bool IsEnabledStartExampleWorkflow()
        {
            return CurrentInOrder != null && !DatabaseApp.IsChanged;
        }

        #endregion


        #region Printing
        public override object Clone()
        {
            BSOInOrder clone = base.Clone() as BSOInOrder;
            if (clone != null)
                clone.PrintPropExample = this.PrintPropExample;
            return clone;
        }

        //public override void OnPrintingPhase(object reportEngine, ACPrintingPhase printingPhase)
        //{
        //    base.OnPrintingPhase(reportEngine, printingPhase);
        //    if (printingPhase == ACPrintingPhase.Started)
        //    {
        //        ReportDocument currentPrintingDoc = reportEngine as ReportDocument;
        //        if (currentPrintingDoc != null)
        //        {
        //            ReportData reportData = (currentPrintingDoc.ReportData as IList<ReportData>).FirstOrDefault();
        //            if (reportData != null && reportData.ACClassDesign != null)
        //            {
        //                if (reportData.ACClassDesign.ACIdentifier == "TableRowDataDyn")
        //                {
        //                    DataTable dataTable = CreateOrderTable();
        //                    InsertOrders(dataTable);
        //                    if (reportData.ReportDocumentValues.ContainsKey("DataTableOrder"))
        //                        reportData.ReportDocumentValues.Remove("DataTableOrder");
        //                    reportData.ReportDocumentValues.Add("DataTableOrder", dataTable);
        //                }
        //            }
        //            // Subscribe to printing events
        //            currentPrintingDoc.NextRow += OnPrinting_NextRow;
        //            currentPrintingDoc.NewCell += OnPrinting_NewCell;
        //            currentPrintingDoc.SetFlowDocObjValue += OnPrinting_SetFlowDocObjValue;
        //        }
        //    }
        //    else //if (printingPhase == ACPrintingPhase.Completed || printingPhase == ACPrintingPhase.Cancelled)
        //    {
        //        ReportDocument currentPrintingDoc = reportEngine as ReportDocument;
        //        if (currentPrintingDoc != null)
        //        {
        //            if (printingPhase == ACPrintingPhase.Completed)
        //            {
        //                if ((currentPrintingDoc.PageWidth + currentPrintingDoc.PageHeight) > 2000)
        //                    currentPrintingDoc.AutoSelectPrinterName = "LaserJetA3";
        //                else
        //                    currentPrintingDoc.AutoSelectPrinterName = "LaserJetA4";
        //            }
        //            // Unsubscribe printing events
        //            currentPrintingDoc.NextRow -= OnPrinting_NextRow;
        //            currentPrintingDoc.NewCell -= OnPrinting_NewCell;
        //            currentPrintingDoc.SetFlowDocObjValue -= OnPrinting_SetFlowDocObjValue;
        //        }
        //    }
        //}

        //void OnPrinting_SetFlowDocObjValue(object sender, PaginatorOnSetValueEventArgs e)
        //{
        //    ReportDocument currentPrintingDoc = sender as ReportDocument;
        //    if (currentPrintingDoc != null && e.FlowDocObj.VBContent == "TargetQuantity")
        //    {
        //        TextElement element = e.FlowDocObj as TextElement;
        //        if (element != null)
        //            element.FontWeight = FontWeights.Bold;
        //    }
        //}

        //void OnPrinting_NewCell(object sender, PaginatorNewTableCellEventArgs e)
        //{
        //    if (e.FieldName == "TargetQuantity" && e.FieldValue != null && e.FieldValue is double)
        //    {
        //        double value = (double)e.FieldValue;
        //        if (value > 0.0001)
        //        {
        //            string valueAsString = InlineValueBase.FormatValue(value, "0.0000", (e.TableRow as TableRowDataBase).CultureInfo, (e.TableRow as TableRowDataBase).MaxLength, (e.TableRow as TableRowDataBase).Truncate);
        //            (((e.NewCell.Blocks.FirstBlock as System.Windows.Documents.Paragraph)).Inlines.FirstInline as Run).Text = valueAsString;
        //        }
        //    }
        //}

        //void OnPrinting_NextRow(object sender, PaginatorNextRowEventArgs e)
        //{
        //}

        private static DataTable CreateOrderTable()
        {
            DataTable orderTable = new DataTable("Order");

            DataColumn colId = new DataColumn("OrderId", typeof(String));
            orderTable.Columns.Add(colId);

            DataColumn colDate = new DataColumn("OrderDate", typeof(DateTime));
            orderTable.Columns.Add(colDate);

            orderTable.PrimaryKey = new DataColumn[] { colId };

            return orderTable;
        }

        private static void InsertOrders(DataTable orderTable)
        {
            // Add one row once.
            DataRow row1 = orderTable.NewRow();
            row1["OrderId"] = "O0001";
            row1["OrderDate"] = new DateTime(2013, 3, 1);
            orderTable.Rows.Add(row1);

            DataRow row2 = orderTable.NewRow();
            row2["OrderId"] = "O0002";
            row2["OrderDate"] = new DateTime(2013, 3, 12);
            orderTable.Rows.Add(row2);

            DataRow row3 = orderTable.NewRow();
            row3["OrderId"] = "O0003";
            row3["OrderDate"] = new DateTime(2013, 3, 20);
            orderTable.Rows.Add(row3);
        }
        #endregion

        #endregion


        #region Execute-Helper

        protected override bool HandleExecuteACMethod(out object result, AsyncMethodInvocationMode invocationMode, string acMethodName, ACClassMethod acClassMethod, params object[] acParameter)
        {
            result = null;
            switch (acMethodName)
            {
                case "Save":
                    Save();
                    return true;
                case "IsEnabledSave":
                    result = IsEnabledSave();
                    return true;
                case "UndoSave":
                    UndoSave();
                    return true;
                case "IsEnabledUndoSave":
                    result = IsEnabledUndoSave();
                    return true;
                case "Load":
                    Load(acParameter.Count() == 1 ? (Boolean)acParameter[0] : false);
                    return true;
                case "IsEnabledLoad":
                    result = IsEnabledLoad();
                    return true;
                case "New":
                    New();
                    return true;
                case "IsEnabledNew":
                    result = IsEnabledNew();
                    return true;
                case "Delete":
                    Delete();
                    return true;
                case "IsEnabledDelete":
                    result = IsEnabledDelete();
                    return true;
                case "Search":
                    Search();
                    return true;
                case "NewInOrderPos":
                    NewInOrderPos();
                    return true;
                case "IsEnabledNewInOrderPos":
                    result = IsEnabledNewInOrderPos();
                    return true;
                case "DeleteInOrderPos":
                    DeleteInOrderPos();
                    return true;
                case "IsEnabledDeleteInOrderPos":
                    result = IsEnabledDeleteInOrderPos();
                    return true;
                case "DisplaySum":
                    DisplaySum();
                    return true;
                case "StartExampleWorkflow":
                    StartExampleWorkflow();
                    return true;
                case "IsEnabledStartExampleWorkflow":
                    result = IsEnabledStartExampleWorkflow();
                    return true;
            }
            return base.HandleExecuteACMethod(out result, invocationMode, acMethodName, acClassMethod, acParameter);
        }

        #endregion
    }
}
