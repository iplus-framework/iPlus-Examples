using System;
using System.Collections.Generic;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Infrastructure;
using gip.core.datamodel;

namespace mycompany.package.datamodel;

public partial class InOrder : VBEntityObject , IInsertInfo, IUpdateInfo
{

    public InOrder()
    {
    }

    private InOrder(ILazyLoader lazyLoader)
    {
        LazyLoader = lazyLoader;
    }

    private ILazyLoader LazyLoader { get; set; }
    
    Guid _InOrderID;
    public Guid InOrderID 
    {
        get { return _InOrderID; }
        set { SetProperty<Guid>(ref _InOrderID, value); }
    }

    string _InOrderNo;
    public string InOrderNo 
    {
        get { return _InOrderNo; }
        set { SetProperty<string>(ref _InOrderNo, value); }
    }

    DateTime _InOrderDate;
    public DateTime InOrderDate 
    {
        get { return _InOrderDate; }
        set { SetProperty<DateTime>(ref _InOrderDate, value); }
    }

    string _Comment;
    public string Comment 
    {
        get { return _Comment; }
        set { SetProperty<string>(ref _Comment, value); }
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

    private ICollection<InOrderPos> _InOrderPos_InOrder;
    public virtual ICollection<InOrderPos> InOrderPos_InOrder
    {
        get { return LazyLoader.Load(this, ref _InOrderPos_InOrder); }
        set { _InOrderPos_InOrder = value; }
    }

    public bool InOrderPos_InOrder_IsLoaded
    {
        get
        {
            return _InOrderPos_InOrder != null;
        }
    }

    public virtual CollectionEntry InOrderPos_InOrderReference
    {
        get { return Context.Entry(this).Collection(c => c.InOrderPos_InOrder); }
    }
}
