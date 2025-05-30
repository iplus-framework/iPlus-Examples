using System;
using System.Collections.Generic;
using System.Linq;
using mycompany.package.datamodel;
using gip.core.datamodel;
using gip.core.autocomponent;

namespace mycompany.bso.erp
{
    [ACClassInfo("mycompany.erp", "en{'Material'}de{'Material'}", Global.ACKinds.TACBSO, Global.ACStorableTypes.NotStorable, true, true, Const.QueryPrefix + nameof(Material))]
    public partial class BSOMaterial : BSOMyCompNav
    {
        #region c'tors
        public BSOMaterial(ACClass acType, IACObject content, IACObject parentACObject, ACValueList parameter, string acIdentifier = "")
            : base(acType, content, parentACObject, parameter, acIdentifier)
        {
        }

        public override bool ACInit(Global.ACStartTypes startChildMode = Global.ACStartTypes.Automatic)
        {
            if (!base.ACInit(startChildMode))
                return false;
            Search();
            return true;
        }

        public override bool ACDeInit(bool deleteACClassTask = false)
        {
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
        public override IAccessNav AccessNav { get { return AccessPrimary; } }
        ACAccessNav<Material> _AccessPrimary;
        [ACPropertyAccessPrimary(9999, nameof(Material))]
        public ACAccessNav<Material> AccessPrimary
        {
            get
            {
                if (_AccessPrimary == null && ACType != null)
                {
                    ACQueryDefinition acQueryDef = Root.Queries.CreateQueryByClass(null, PrimaryNavigationquery(), ACType.ACIdentifier);
                    if (acQueryDef != null)
                    {
                        acQueryDef.CheckAndReplaceColumnsIfDifferent(NavigationqueryDefaultFilter, NavigationqueryDefaultSort);
                    }
                    _AccessPrimary = acQueryDef.NewAccessNav<Material>(nameof(Material), this);

                }
                return _AccessPrimary;
            }
        }

        protected virtual List<ACFilterItem> NavigationqueryDefaultFilter
        {
            get
            {
                return new List<ACFilterItem>()
                {
                    new ACFilterItem(Global.FilterTypes.filter, "MaterialNo", Global.LogicalOperators.contains, Global.Operators.or, null, true, true),
                    new ACFilterItem(Global.FilterTypes.filter, "MaterialName1", Global.LogicalOperators.contains, Global.Operators.or, null, true, true),
                };
            }
        }

        protected virtual List<ACSortItem> NavigationqueryDefaultSort
        {
            get
            {
                return new List<ACSortItem>()
                {
                    new ACSortItem("MaterialNo", Global.SortDirections.ascending, true)
                };
            }
        }

        [ACPropertyList(300, nameof(Material), "en{'Material List'}de{'Materiallliste'}")]
        public IList<Material> MaterialList
        {
            get
            {
                return AccessPrimary.NavList;
            }
        }

        [ACPropertyCurrent(301, nameof(Material), "en{'Material'}de{'Material'}")]
        public Material CurrentMaterial
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
                OnPropertyChanged("CurrentMaterial");
            }
        }

        [ACPropertySelected(302, nameof(Material), "en{'Material'}de{'Material'}")]
        public Material SelectedMaterial
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
                OnPropertyChanged("SelectedMaterial");
            }
        }
        #endregion


        #region BSO->ACMethod

        #region ControlMode
        /// <summary>Called inside the GetControlModes-Method to get the Global.ControlModes from derivations.
        /// This method should be overriden in the derivations to dynmically control the presentation mode depending on the current value which is bound via VBContent</summary>
        /// <param name="vbControl">A WPF-Control that implements IVBContent</param>
        /// <returns>ControlModesInfo</returns>
        public override Global.ControlModes OnGetControlModes(IVBContent vbControl)
        {
            if (vbControl == null)
                return base.OnGetControlModes(vbControl);

            Global.ControlModes result = base.OnGetControlModes(vbControl);
            if (result < Global.ControlModes.Enabled)
                return result;
            //switch (vbControl.VBContent)
            //{
            //    case "CurrentMaterial\\BaseMDUnit":
            //    default:
            //        return result;
            //}
            return result;
        }
        #endregion

        #region BSO->ACMethod->Material
        [ACMethodCommand(nameof(Material), "en{'Save'}de{'Speichern'}", (short)MISort.Save, false, Global.ACKinds.MSMethodPrePost)]
        public void Save()
        {
            OnSave();
            DatabaseApp.OnPropertyChanged(nameof(Material));
        }

        public bool IsEnabledSave()
        {
            return OnIsEnabledSave();
        }

        [ACMethodCommand(nameof(Material), "en{'Undo'}de{'Nicht speichern'}", (short)MISort.UndoSave, false, Global.ACKinds.MSMethodPrePost)]
        public void UndoSave()
        {
            OnUndoSave();
            Load();
        }

        public bool IsEnabledUndoSave()
        {
            return OnIsEnabledUndoSave();
        }

        private bool _IsLoadDisabled = false;
        [ACMethodInteraction(nameof(Material), "en{'Load'}de{'Laden'}", (short)MISort.Load, false, "SelectedMaterial", Global.ACKinds.MSMethodPrePost)]
        public void Load(bool requery = false)
        {
            if (!PreExecute("Load"))
                return;
            if (_IsLoadDisabled)
                return;
            _IsLoadDisabled = true;
            LoadEntity<Material>(requery, () => SelectedMaterial, () => CurrentMaterial, c => CurrentMaterial = c,
                        DatabaseApp.Material
                        .Where(c => c.MaterialID == SelectedMaterial.MaterialID));
            PostExecute("Load");
            _IsLoadDisabled = false;
        }

        public bool IsEnabledLoad()
        {
            return SelectedMaterial != null;
        }

        [ACMethodInteraction(nameof(Material), "en{'New'}de{'Neu'}", (short)MISort.New, true, "SelectedMaterial", Global.ACKinds.MSMethodPrePost)]
        public void New()
        {
            CurrentMaterial = Material.NewACObject(DatabaseApp, null);
            DatabaseApp.Material.Add(CurrentMaterial);
            AccessPrimary.NavList.Add(CurrentMaterial);
            AccessPrimary.Selected = CurrentMaterial;
            OnPropertyChanged("SelectedMaterial");
        }

        public bool IsEnabledNew()
        {
            return true;
        }

        [ACMethodInteraction(nameof(Material), "en{'Delete'}de{'Löschen'}", (short)MISort.Delete, true, "CurrentMaterial", Global.ACKinds.MSMethodPrePost)]
        public void Delete()
        {
            string dialog = CurrentMaterial.DeleteDate == null ? "DialogSoftDelete" : "DialogUnDelete";
            ShowDialog(this, dialog);
        }

        public bool IsEnabledDelete()
        {
            return CurrentMaterial != null;
        }

        public override void OnDelete(bool softDelete)
        {
            Msg msg = CurrentMaterial.DeleteACObject(DatabaseApp, true, softDelete);
            if (msg != null)
            {
                Root.Messages.Msg(msg);
                return;
            }

            _IsLoadDisabled = true;
            if (AccessPrimary == null)
                return;
            AccessPrimary.NavList.Remove(CurrentMaterial);
            SelectedMaterial = AccessPrimary.NavList.FirstOrDefault();
            PostExecute("Delete");
            _IsLoadDisabled = false;
            Load();
            OnPropertyChanged("MaterialList");

        }

        public override void OnRestore()
        {
            base.OnRestore();
            DatabaseApp.SaveChanges();
            Search();
            OnPropertyChanged("MaterialList");
        }

        [ACMethodCommand(nameof(Material), "en{'Search'}de{'Suchen'}", (short)MISort.Search)]
        public void Search()
        {
            AccessPrimary.NavSearch(DatabaseApp, DatabaseApp.RecommendedMergeOption);
            OnPropertyChanged("MaterialList");
        }

        #endregion

        #endregion


        #region Execute-Helper-Handlers
        protected override bool HandleExecuteACMethod(out object result, AsyncMethodInvocationMode invocationMode, string acMethodName, ACClassMethod acClassMethod, params object[] acParameter)
        {
            result = null;
            switch (acMethodName)
            {
                case nameof(Save):
                    Save();
                    return true;
                case nameof(IsEnabledSave):
                    result = IsEnabledSave();
                    return true;
                case nameof(UndoSave):
                    UndoSave();
                    return true;
                case nameof(IsEnabledUndoSave):
                    result = IsEnabledUndoSave();
                    return true;
                case nameof(Load):
                    Load(acParameter.Count() == 1 ? (Boolean)acParameter[0] : false);
                    return true;
                case nameof(IsEnabledLoad):
                    result = IsEnabledLoad();
                    return true;
                case nameof(New):
                    New();
                    return true;
                case nameof(IsEnabledNew):
                    result = IsEnabledNew();
                    return true;
                case nameof(Delete):
                    Delete();
                    return true;
                case nameof(IsEnabledDelete):
                    result = IsEnabledDelete();
                    return true;
                case nameof(Search):
                    Search();
                    return true;
            }
            return base.HandleExecuteACMethod(out result, invocationMode, acMethodName, acClassMethod, acParameter);
        }
        #endregion
    }
}
