using System;
using System.Collections.Generic;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Infrastructure;
using gip.core.datamodel;

namespace mycompany.package.datamodel;

public partial class InOrderPos : VBEntityObject , IInsertInfo, IUpdateInfo
{

    public InOrderPos()
    {
    }

    private InOrderPos(ILazyLoader lazyLoader)
    {
        LazyLoader = lazyLoader;
    }

    private ILazyLoader LazyLoader { get; set; }
    
    Guid _InOrderPosID;
    public Guid InOrderPosID 
    {
        get { return _InOrderPosID; }
        set { SetProperty<Guid>(ref _InOrderPosID, value); }
    }

    Guid _InOrderID;
    public Guid InOrderID 
    {
        get { return _InOrderID; }
        set { SetProperty<Guid>(ref _InOrderID, value); }
    }

    int _Sequence;
    public int Sequence 
    {
        get { return _Sequence; }
        set { SetProperty<int>(ref _Sequence, value); }
    }

    Guid _MaterialID;
    public Guid MaterialID 
    {
        get { return _MaterialID; }
        set { SetProperty<Guid>(ref _MaterialID, value); }
    }

    double _TargetQuantity;
    public double TargetQuantity 
    {
        get { return _TargetQuantity; }
        set { SetProperty<double>(ref _TargetQuantity, value); }
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

    private InOrder _InOrder;
    public virtual InOrder InOrder
    { 
        get { return LazyLoader.Load(this, ref _InOrder); } 
        set { SetProperty<InOrder>(ref _InOrder, value); }
    }

    public bool InOrder_IsLoaded
    {
        get
        {
            return _InOrder != null;
        }
    }

    public virtual ReferenceEntry InOrderReference 
    {
        get { return Context.Entry(this).Reference("InOrder"); }
    }
    
    private Material _Material;
    public virtual Material Material
    { 
        get { return LazyLoader.Load(this, ref _Material); } 
        set { SetProperty<Material>(ref _Material, value); }
    }

    public bool Material_IsLoaded
    {
        get
        {
            return _Material != null;
        }
    }

    public virtual ReferenceEntry MaterialReference 
    {
        get { return Context.Entry(this).Reference("Material"); }
    }
    }
