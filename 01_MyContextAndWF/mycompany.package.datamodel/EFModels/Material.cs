using System;
using System.Collections.Generic;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Infrastructure;
using gip.core.datamodel;

namespace mycompany.package.datamodel;

public partial class Material : VBEntityObject , IInsertInfo, IUpdateInfo
{

    public Material()
    {
    }

    private Material(ILazyLoader lazyLoader)
    {
        LazyLoader = lazyLoader;
    }

    private ILazyLoader LazyLoader { get; set; }
    
    Guid _MaterialID;
    public Guid MaterialID 
    {
        get { return _MaterialID; }
        set { SetProperty<Guid>(ref _MaterialID, value); }
    }

    string _MaterialNo;
    public string MaterialNo 
    {
        get { return _MaterialNo; }
        set { SetProperty<string>(ref _MaterialNo, value); }
    }

    string _MaterialName1;
    public string MaterialName1 
    {
        get { return _MaterialName1; }
        set { SetProperty<string>(ref _MaterialName1, value); }
    }

    string _XMLConfig;
    public override string XMLConfig 
    {
        get { return _XMLConfig; }
        set { SetProperty<string>(ref _XMLConfig, value); }
    }

    string _InsertName;
    public string InsertName 
    {
        get { return _InsertName; }
        set { SetProperty<string>(ref _InsertName, value); }
    }

    DateTime _InsertDate;
    public DateTime InsertDate 
    {
        get { return _InsertDate; }
        set { SetProperty<DateTime>(ref _InsertDate, value); }
    }

    string _UpdateName;
    public string UpdateName 
    {
        get { return _UpdateName; }
        set { SetProperty<string>(ref _UpdateName, value); }
    }

    DateTime _UpdateDate;
    public DateTime UpdateDate 
    {
        get { return _UpdateDate; }
        set { SetProperty<DateTime>(ref _UpdateDate, value); }
    }

    DateTime? _DeleteDate;
    public DateTime? DeleteDate 
    {
        get { return _DeleteDate; }
        set { SetProperty<DateTime?>(ref _DeleteDate, value); }
    }

    string _DeleteName;
    public string DeleteName 
    {
        get { return _DeleteName; }
        set { SetProperty<string>(ref _DeleteName, value); }
    }

    private ICollection<InOrderPos> _InOrderPos_Material;
    public virtual ICollection<InOrderPos> InOrderPos_Material
    {
        get { return LazyLoader.Load(this, ref _InOrderPos_Material); }
        set { _InOrderPos_Material = value; }
    }

    public bool InOrderPos_Material_IsLoaded
    {
        get
        {
            return _InOrderPos_Material != null;
        }
    }

    public virtual CollectionEntry InOrderPos_MaterialReference
    {
        get { return Context.Entry(this).Collection(c => c.InOrderPos_Material); }
    }
}
