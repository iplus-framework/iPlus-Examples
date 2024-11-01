using System;
using System.Collections.Generic;
using System.Linq;
using gip.core.datamodel;
using System.Configuration;
using System.Data;
using System.ComponentModel;
using System.Threading;
using System.Data.Common;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.Data.SqlClient;
using System.ComponentModel.DataAnnotations.Schema;
using Azure.Core;
using Microsoft.CodeAnalysis;
using static Microsoft.EntityFrameworkCore.DbLoggerCategory.Database;
using System.Globalization;
using System.Runtime.CompilerServices;

namespace mycompany.package.datamodel
{
    public static class EntityObjectExtensionApp
    {
        public static TEntityApp FromAppContext<TEntityApp>(this VBEntityObject entityIPlus, MyCompanyDB dbApp) where TEntityApp : VBEntityObject
        {
            if (entityIPlus == null || entityIPlus.EntityKey == null || dbApp == null)
                return default(TEntityApp);
            Type typeOfTargetContext = dbApp.GetType();
            string fullName = typeOfTargetContext.Namespace + "." + entityIPlus.EntityKey.EntitySetName;
            Type typeOfTargetEntity = typeOfTargetContext.Assembly.GetType(fullName);
            if (typeOfTargetEntity == null)
                throw new ArgumentException(String.Format("Type {0} not found in assembly {1}", fullName, typeOfTargetContext.Assembly.ToString()));

            EntityKey key = new EntityKey(fullName, entityIPlus.EntityKey.EntityKeyValues);

            object obj = null;
            using (ACMonitor.Lock(dbApp.QueryLock_1X000))
            {
                if (!dbApp.TryGetObjectByKey(key, out obj))
                    return default(TEntityApp);
            }
            return (TEntityApp)obj;
        }
    }
    /// <summary>
         /// For the implementation of a custom Entity-Framework-Context you have to implement IACEntityObjectContext.
         /// Use gip.core.datamodel.ACObjectContextHelper as a Helper-Class for implementing the IACEntityObjectContext-Members.
         /// Declare the ACClassInfo-Attributeclass with "Global.ACKinds.TACDBAManager". After starting iPlus with "Ctrl-Key + Login-Button", 
         /// this new Entity-Framework-Context-Class will appear in the iPlus development environment in the Variobatch-Tree.
         /// </summary>
         /// <seealso cref="mycompany.package.datamodel.MyCompanyEntities" />
         /// <seealso cref="gip.core.datamodel.IACEntityObjectContext" />
         /// <seealso cref="System.ComponentModel.INotifyPropertyChanged" />
    [ACClassInfo("mycompany.erp", "en{'Database application'}de{'Datenbank Anwendung'}", Global.ACKinds.TACDBAManager, Global.ACStorableTypes.NotStorable, false, false)]
    public partial class MyCompanyDB : MyCompanyDBContext, IACEntityObjectContext, INotifyPropertyChanged
    {
        #region c'tors
        public MyCompanyDB()
            : base(EntityObjectExtension.DbContextOptions<MyCompanyDBContext>(ConnectionString))
        {
            _ObjectContextHelper = new ACObjectContextHelper(this);
        }

        public MyCompanyDB(string connectionString)
            : base(EntityObjectExtension.DbContextOptions<MyCompanyDBContext>(connectionString))
        {
            _ObjectContextHelper = new ACObjectContextHelper(this);
        }

        public MyCompanyDB(Database contextIPlus)
            : base(EntityObjectExtension.DbContextOptions<MyCompanyDBContext>(ConnectionString))
        {
            _ObjectContextHelper = new ACObjectContextHelper(this);
            _ContextIPlus = contextIPlus;
        }

        public MyCompanyDB(string connectionString, Database contextIPlus)
            : base(EntityObjectExtension.DbContextOptions<MyCompanyDBContext>(connectionString))
        {
            _ObjectContextHelper = new ACObjectContextHelper(this);
            _ContextIPlus = contextIPlus;
        }

        public MyCompanyDB(bool createSeparateConnection)
            : this(new SqlConnection(ConnectionString))
        {
        }

        public MyCompanyDB(bool createSeparateConnection, Database contextIPlus)
            : this(new SqlConnection(ConnectionString))
        {
        }

        public MyCompanyDB(DbConnection connection)
            : base(EntityObjectExtension.DbContextOptions<MyCompanyDBContext>(connection))
        {
            _SeparateConnection = connection;
            _ObjectContextHelper = new ACObjectContextHelper(this);
        }

        public MyCompanyDB(DbConnection connection, Database contextIPlus)
            : base(EntityObjectExtension.DbContextOptions<MyCompanyDBContext>(connection))
        {
            _SeparateConnection = connection;
            _ObjectContextHelper = new ACObjectContextHelper(this);
            _ContextIPlus = contextIPlus;
        }

        static MyCompanyDB()
        {
            //if (!Global.ContextMenuCategoryList.Where(c => (short)c.Value == (short)Global.ContextMenuCategory.ProdPlanLog).Any())
            //    Global.ContextMenuCategoryList.Add(new ACValueItem("en{'Production, Plannung & Logistics'}de{'Production, Plannung & Logistics'}", (short)Global.ContextMenuCategory.ProdPlanLog, null, null, 250));
        }

        public override void Dispose()
        {
            if (_ObjectContextHelper != null)
                _ObjectContextHelper.Dispose();
            _ObjectContextHelper = null;
            _ContextIPlus = null;
            base.Dispose();
            if (SeparateConnection != null)
                SeparateConnection.Dispose();
            _SeparateConnection = null;
        }

        /// <summary>
        /// Dient zum erstmaligen initialiseren der Datenban beim Startup
        /// damit csdl und msal flies geladen werden.
        /// Dadurch wird das erstmalige Öffnen eines BSO's und der erste Speichervorgang beschleunigt.
        /// </summary>
        public static void InitializeDBOnStartup()
        {
            if (_AppDBOnStartupInitialized)
                return;
            _AppDBOnStartupInitialized = true;
            // Nicht über die Queue, sondern es muss der Statvorgang abgewartet werden!
            //RootDbOpQueue.ACClassTaskQueue.Add(() =>
            {
                using (MyCompanyDB dbApp = new MyCompanyDB())
                {
                    //dbApp.ACAssembly.FirstOrDefault();
                }
            }
            //);
        }

        #endregion

        #region Properties

        #region Private
        private ACObjectContextHelper _ObjectContextHelper;
        private Database _ContextIPlus;
        private static bool _AppDBOnStartupInitialized = false;
        #endregion

        #region Public Static
        public static string ConnectionString
        {
            get
            {
                if (CommandLineHelper.ConfigCurrentDir != null && CommandLineHelper.ConfigCurrentDir.ConnectionStrings != null)
                {
                    try
                    {
                        ConnectionStringSettings setting = CommandLineHelper.ConfigCurrentDir.ConnectionStrings.ConnectionStrings["MyCompanyDB_Entities"];
                        return setting.ConnectionString;
                    }
                    catch (Exception ec)
                    {
                        string msg = ec.Message;
                        if (ec.InnerException != null && ec.InnerException.Message != null)
                            msg += " Inner:" + ec.InnerException.Message;

                        if (gip.core.datamodel.Database.Root != null && gip.core.datamodel.Database.Root.Messages != null && gip.core.datamodel.Database.Root.InitState == ACInitState.Initialized)
                            gip.core.datamodel.Database.Root.Messages.LogException("MyCompanyDB", "ConnectionString", msg);
                    }
                }
                return ConfigurationManager.ConnectionStrings["MyCompanyDB_Entities"].ConnectionString;
            }
        }

        /// <summary>
        /// Method for changing Connection-String to generate own connectionpool
        /// </summary>
        /// <param name="appName"></param>
        /// <returns></returns>
        public static string ModifiedConnectionString(string appName)
        {
            var connString = ConnectionString.Replace("iPlus_dbApp", appName);
            return connString;
        }
        #endregion

        #region Public
        [ACPropertyInfo(9999)]
        public Database ContextIPlus
        {
            get
            {
                return _ContextIPlus == null ? gip.core.datamodel.Database.GlobalDatabase : _ContextIPlus;
            }
        }

        public bool IsSeparateIPlusContext
        {
            get
            {
                if (_ContextIPlus == null)
                    return false;
                else if (_ContextIPlus == gip.core.datamodel.Database.GlobalDatabase)
                    return false;
                return true;
            }
        }

        public DbConnection Connection
        {
            get
            {
                return ContextIPlus.Connection;
            }
        }

        DbConnection _SeparateConnection;
        public DbConnection SeparateConnection
        {
            get
            {
                return _SeparateConnection;
            }
        }

        private string _UserName;
        public string UserName
        {
            get
            {
                if (!String.IsNullOrEmpty(_UserName))
                    return _UserName;
                if (Database.Root == null
                    || !gip.core.datamodel.Database.Root.Initialized
                    || gip.core.datamodel.Database.Root.Environment == null
                    || gip.core.datamodel.Database.Root.Environment.User == null)
                    return "Init";
                _UserName = gip.core.datamodel.Database.Root.Environment.User.Initials;
                return _UserName;
            }
            set
            {
                _UserName = value;
            }
        }



        /// <summary>
        /// THREAD-SAFE. Uses QueryLock_1X000
        /// </summary>
        /// <returns></returns>
        [ACPropertyInfo(9999)]
        public bool IsChanged
        {
            get
            {
                if (_ObjectContextHelper == null)
                    return false;
                return _ObjectContextHelper.IsChanged;
            }
        }

        public MergeOption RecommendedMergeOption
        {
            get
            {
                return IsChanged ? MergeOption.AppendOnly : MergeOption.OverwriteChanges;
            }
        }

        public string DefaultContainerName
        {
            get
            {
                return this.GetType().Namespace;
            }
        }

        public event ACChangesEventHandler ACChangesExecuted;

        public bool PreventOnContextACChangesExecuted { get; set; }

        #endregion

        #region IACUrl Member
        /// <summary>
        /// Returns the parent object
        /// </summary>
        /// <value>Reference to the parent object</value>
        public IACObject ParentACObject
        {
            get
            {
                return gip.core.datamodel.Database.Root;
            }
        }

        /// <summary>Translated Label/Description of this instance (depends on the current logon)</summary>
        /// <value>  Translated description</value>
        [ACPropertyInfo(9999)]
        public string ACCaption
        {
            get
            {
                return ACIdentifier;
            }
        }

        /// <summary>Unique Identifier in a Parent-/Child-Relationship.</summary>
        /// <value>The Unique Identifier as string</value>
        [ACPropertyInfo(9999)]
        public string ACIdentifier
        {
            get
            {
                return "";
                //return GetType().Name;
            }
        }

        /// <summary>
        /// A "content list" contains references to the most important data that this instance primarily works with. It is primarily used to control the interaction between users, visual objects, and the data model in a generic way. For example, drag-and-drop or context menu operations. A "content list" can also be null.
        /// </summary>
        /// <value> A nullable list ob IACObjects.</value>
        public IEnumerable<IACObject> ACContentList
        {
            get
            {
                return this.ReflectGetACContentList();
            }
        }

        /// <summary>
        /// Metadata (iPlus-Type) of this instance. ATTENTION: IACType are EF-Objects. Therefore the access to Navigation-Properties must be secured using the QueryLock_1X000 of the Global Database-Context!
        /// </summary>
        /// <value>  iPlus-Type (EF-Object from ACClass*-Tables)</value>
        public IACType ACType
        {
            get
            {
                return this.ReflectACType();
            }
        }
        #endregion

        #endregion

        #region Methods

        #region public
        /// <summary>
        /// Saves all changes in this MyCompanyDB-Context as well as in the iPlus-Context
        /// If ContextIPlus is not seperate  (Property IsSeperateIPlusContext == false / ContextIPlus == Database.GlobalDatabase) then SaveChanges will not be invoked for the global database.
        /// If you wan't that, then you have to pass an new iPlus-Context-Instance to the constructor of the MyCompanyDB-Context!
        /// UNSAFE. Use QueryLock_1X000 outside for Custom-Database-Context as well as for the seperate iPlus-Context
        /// </summary>
        /// <returns></returns>
        [ACMethodInfo("", "", 9999)]
        public MsgWithDetails ACSaveChanges(bool autoSaveContextIPlus = true, bool acceptAllChangesOnSuccess = true, bool validationOff = false, bool writeUpdateInfo = true)
        {
            MsgWithDetails result = _ObjectContextHelper.ACSaveChanges(autoSaveContextIPlus, acceptAllChangesOnSuccess, validationOff, writeUpdateInfo);
            if (result == null)
            {
                if (ACChangesExecuted != null)
                    ACChangesExecuted.Invoke(this, new ACChangesEventArgs(ACChangesEventArgs.ACChangesType.ACSaveChanges, true));
            }
            else
            {
                if (ACChangesExecuted != null)
                    ACChangesExecuted.Invoke(this, new ACChangesEventArgs(ACChangesEventArgs.ACChangesType.ACSaveChanges, false));
            }
            return result;
        }

        /// <summary>
        /// Invokes ACSaveChanges. If a transaction error occurs ACSaveChanges is called again.
        /// If parameter retries ist not set, then ACObjectContextHelper.C_NumberOfRetriesOnTransError is used to limit the Retry-Loop.
        /// </summary>
        [ACMethodInfo("", "", 9999)]
        public MsgWithDetails ACSaveChangesWithRetry(ushort? retries = null, bool autoSaveContextIPlus = true, bool acceptAllChangesOnSuccess = true, bool validationOff = false, bool writeUpdateInfo = true)
        {
            MsgWithDetails result = _ObjectContextHelper.ACSaveChangesWithRetry(retries, autoSaveContextIPlus, acceptAllChangesOnSuccess, validationOff, writeUpdateInfo);
            if (result == null)
            {
                if (ACChangesExecuted != null)
                    ACChangesExecuted.Invoke(this, new ACChangesEventArgs(ACChangesEventArgs.ACChangesType.ACSaveChanges, true));
            }
            else
            {
                if (ACChangesExecuted != null)
                    ACChangesExecuted.Invoke(this, new ACChangesEventArgs(ACChangesEventArgs.ACChangesType.ACSaveChanges, false));
            }
            return result;
        }

        /// <summary>
        /// Undoes all changes in the MyCompanyDB-Context as well as in the iPlus-Context
        /// If ContextIPlus is not seperate  (Property IsSeperateIPlusContext == false / ContextIPlus == Database.GlobalDatabase) then Undo will not be invoked for the global database.
        /// If you wan't that, then you have to pass an new iPlus-Context-Instance to the constructor of the MyCompanyDB-Context!
        /// UNSAFE. Use QueryLock_1X000 outside for MyCompanyDB-Context as well as for the seperate iPlus-Context
        /// </summary>
        /// <returns></returns>
        [ACMethodInfo("", "", 9999)]
        public MsgWithDetails ACUndoChanges(bool autoUndoContextIPlus = true)
        {
            MsgWithDetails result = _ObjectContextHelper.ACUndoChanges(autoUndoContextIPlus);
            if (result == null)
            {
                if (ACChangesExecuted != null)
                    ACChangesExecuted.Invoke(this, new ACChangesEventArgs(ACChangesEventArgs.ACChangesType.ACUndoChanges, true));
            }
            else
            {
                if (ACChangesExecuted != null)
                    ACChangesExecuted.Invoke(this, new ACChangesEventArgs(ACChangesEventArgs.ACChangesType.ACUndoChanges, false));
            }
            return result;
        }

        /// <summary>
        /// THREAD-SAFE. Uses QueryLock_1X000
        /// </summary>
        /// <returns></returns>
        public bool HasModifiedObjectStateEntries()
        {
            return _ObjectContextHelper.HasModifiedObjectStateEntries();
        }

        /// <summary>
        /// THREAD-SAFE. Uses QueryLock_1X000
        /// </summary>
        /// <returns></returns>
        public bool HasAddedEntities<T>() where T : class
        {
            return _ObjectContextHelper.HasAddedEntities<T>();
        }

        /// <summary>
        /// THREAD-SAFE. Uses QueryLock_1X000
        /// returns Entities with EntityState.Added-State only
        /// </summary>
        /// <returns></returns>
        public IList<T> GetAddedEntities<T>(Func<T, bool> selector = null) where T : class
        {
            return _ObjectContextHelper.GetChangedEntities<T>(EntityState.Added, selector);
        }

        /// <summary>
        /// THREAD-SAFE. Uses QueryLock_1X000
        /// returns Entities with EntityState.Modified-State only
        /// </summary>
        /// <returns></returns>
        public IList<T> GetModifiedEntities<T>(Func<T, bool> selector = null) where T : class
        {
            return _ObjectContextHelper.GetChangedEntities<T>(EntityState.Modified, selector);
        }

        /// <summary>
        /// THREAD-SAFE. Uses QueryLock_1X000
        /// returns Entities with EntityState.Deleted-State only
        /// </summary>
        /// <returns></returns>
        public IList<T> GetDeletedEntities<T>(Func<T, bool> selector = null) where T : class
        {
            return _ObjectContextHelper.GetChangedEntities<T>(EntityState.Deleted, selector);
        }

        /// <summary>
        /// THREAD-SAFE. Uses QueryLock_1X000
        /// returns Entities with EntityState.Detached-State only
        /// </summary>
        /// <returns></returns>
        public IList<T> GetDetachedEntities<T>(Func<T, bool> selector = null) where T : class
        {
            return _ObjectContextHelper.GetChangedEntities<T>(EntityState.Detached, selector);
        }

        /// <summary>
        /// THREAD-SAFE. Uses QueryLock_1X000
        /// returns Entities with EntityState.Unchanged-State only
        /// </summary>
        /// <returns></returns>
        public IList<T> GetUnchangedEntities<T>(Func<T, bool> selector = null) where T : class
        {
            return _ObjectContextHelper.GetChangedEntities<T>(EntityState.Unchanged, selector);
        }

        /// <summary>
        /// THREAD-SAFE. Uses QueryLock_1X000
        /// returns EntityState.Modified | EntityState.Added | EntityState.Deleted
        /// </summary>
        /// <returns></returns>
        public IList<T> GetChangedEntities<T>(Func<T, bool> selector = null) where T : class
        {
            return _ObjectContextHelper.GetChangedEntities<T>(EntityState.Modified | EntityState.Added | EntityState.Deleted, selector);
        }

        /// <summary>
        /// UNSAFE. Use QueryLock_1X000 outside
        /// </summary>
        /// <returns></returns>
        public IList<Msg> CheckChangedEntities()
        {
            return _ObjectContextHelper.CheckChangedEntities();
        }

        /// <summary>
        /// Refreshes the EntityObject if not in modified state. Else it leaves it untouched.
        /// </summary>
        /// <param name="entityObject"></param>
        public void AutoRefresh(VBEntityObject entityObject)
        {
            _ObjectContextHelper.AutoRefresh(entityObject);
        }

        /// <summary>
        /// Refreshes all EntityObjects in the EntityCollection if not in modified state. Else it leaves it untouched.
        /// Attention: This method will only refresh the entities with entity keys that are tracked by the ObjectContext. 
        /// If changes are made in background on the database you shoud use the method AutoLoad, to retrieve new Entries from the Database!
        /// </summary>
        /// <typeparam name="T"></typeparam>
        /// <param name="entityCollection"></param>
        public void AutoRefresh<T>(ICollection<T> entityCollection, CollectionEntry entry) where T : class
        {
            _ObjectContextHelper.AutoRefresh<T>(entityCollection, entry);
        }

        /// <summary>
        /// Queries the Database an refreshes the collection if not in modified state. MergeOption.OverwriteChanges
        /// Els if in modified state, then colletion is only refreshed with MergeOption.AppendOnly
        /// </summary>
        /// <typeparam name="T"></typeparam>
        /// <param name="entityCollection"></param>
        public void AutoLoad<T>(ICollection<T> entityCollection, CollectionEntry entry) where T : class
        {
            _ObjectContextHelper.AutoLoad<T>(entityCollection, entry);
        }

        public void ParseException(MsgWithDetails msg, Exception e)
        {
            _ObjectContextHelper.ParseException(msg, e);
        }

        #region IACUrl Member
        /// <summary>
        /// The ACUrlCommand is a universal method that can be used to query the existence of an instance via a string (ACUrl) to:
        /// 1. get references to components,
        /// 2. query property values,
        /// 3. execute method calls,
        /// 4. start and stop Components,
        /// 5. and send messages to other components.
        /// </summary>
        /// <param name="acUrl">String that adresses a command</param>
        /// <param name="acParameter">Parameters if a method should be invoked</param>
        /// <returns>Result if a property was accessed or a method was invoked. Void-Methods returns null.</returns>
        public object ACUrlCommand(string acUrl, params Object[] acParameter)
        {
            if (_ObjectContextHelper == null)
                return null;
            return _ObjectContextHelper.ACUrlCommand(acUrl, acParameter);
        }

        /// <summary>
        /// This method is called before ACUrlCommand if a method-command was encoded in the ACUrl
        /// </summary>
        /// <param name="acUrl">String that adresses a command</param>
        /// <param name="acParameter">Parameters if a method should be invoked</param>
        /// <returns>true if ACUrlCommand can be invoked</returns>
        public bool IsEnabledACUrlCommand(string acUrl, params Object[] acParameter)
        {
            return true;
        }

        /// <summary>
        /// Method that returns a source and path for WPF-Bindings by passing a ACUrl.
        /// </summary>
        /// <param name="acUrl">ACUrl of the Component, Property or Method</param>
        /// <param name="acTypeInfo">Reference to the iPlus-Type (ACClass)</param>
        /// <param name="source">The Source for WPF-Databinding</param>
        /// <param name="path">Relative path from the returned source for WPF-Databinding</param>
        /// <param name="rightControlMode">Information about access rights for the requested object</param>
        /// <returns><c>true</c> if binding could resolved for the passed ACUrl<c>false</c> otherwise</returns>
        public bool ACUrlBinding(string acUrl, ref IACType acTypeInfo, ref object source, ref string path, ref Global.ControlModes rightControlMode)
        {
            if (_ObjectContextHelper == null)
                return false;
            return _ObjectContextHelper.ACUrlBinding(acUrl, ref acTypeInfo, ref source, ref path, ref rightControlMode);
        }

        [ACMethodInfo("", "", 9999)]
        public string GetACUrlComponent(IACObject rootACObject = null)
        {
            throw new NotImplementedException();
        }

        /// <summary>
        /// Returns a ACUrl relatively to the passed object.
        /// If the passed object is null then the absolute path is returned
        /// </summary>
        /// <param name="rootACObject">Object for creating a realtive path to it</param>
        /// <returns>ACUrl as string</returns>
        [ACMethodInfo("", "", 9999)]
        public string GetACUrl(IACObject rootACObject = null)
        {
            return ACIdentifier;
        }

        public void FullDetach(VBEntityObject obj)
        {
            Detach(obj);
            // General Problem of ObjectContext-MAnager
            // When a object should be detached, then the object which have a relational relationship will not be deatched
            // The Information about the relation are stored in the internal Member _danglingForeignKeys of the ObjectContextManager
            // This entries will never be deleted - so the memory increases for long term open contexts
            // See under: http://referencesource.microsoft.com/#System.Data.Entity/System/Data/Objects/ObjectStateManager.cs
            // The following code is a first attempt to empty this cache:
            /*if (this.ObjectStateManager == null)
                return;
            ObjectStateEntry entry = null;
            if (!this.ObjectStateManager.TryGetObjectStateEntry(obj.EntityKey, out entry))
                return;
            try
            {
                this.Detach(obj);
                Type tOSM = this.ObjectStateManager.GetType();
                //RemoveForeignKeyFromIndex(EntityKey foreignKey)
                //MethodInfo mi = tOSM.GetMethod("FixupKey", BindingFlags.Instance | BindingFlags.NonPublic);
                //mi.Invoke(this.ObjectStateManager, new object[] { entry });
                MethodInfo mi = tOSM.GetMethod("RemoveForeignKeyFromIndex", BindingFlags.Instance | BindingFlags.NonPublic);
                mi.Invoke(this.ObjectStateManager, new object[] { obj.EntityKey });
            }
            ctch
            {
            }*/
        }
        #endregion

        #endregion

        #region Critical Section
        public void EnterCS()
        {
            _ObjectContextHelper.EnterCS();
        }

        public void EnterCS(bool DeactivateEntityCheck)
        {
            _ObjectContextHelper.EnterCS(DeactivateEntityCheck);
        }

        public void LeaveCS()
        {
            _ObjectContextHelper.LeaveCS();
        }

        [NotMapped]
        private ACMonitorObject _11000_QueryLock_ = new ACMonitorObject(11000);
        [NotMapped]
        public ACMonitorObject QueryLock_1X000
        {
            get
            {
                return _11000_QueryLock_;
            }
        }

        #endregion

        #endregion

        #region DBSetToList

        //[ACPropertyInfo(9999)]
        //[NotMapped]
        //public IEnumerable<InOrder> InOrderList
        //{
        //    get
        //    {
        //        return InOrder.ToArray();
        //    }
        //}

        //[ACPropertyInfo(9999)]
        //[NotMapped]
        //public IEnumerable<InOrderPos> InOrderPosList
        //{
        //    get
        //    {
        //        return InOrderPos.ToArray();
        //    }
        //}

        //[ACPropertyInfo(9999)]
        //[NotMapped]
        //public IEnumerable<Material> MaterialList
        //{
        //    get
        //    {
        //        return Material.ToArray();
        //    }
        //}

        #endregion

        #region INotifyPropertyChanged
        public event PropertyChangedEventHandler PropertyChanged;


        public void OnPropertyChanged([CallerMemberName] string propertyName = "")
        {
            if (PropertyChanged != null)
            {
                PropertyChanged(this, new PropertyChangedEventArgs(propertyName));
            }
        }
        #endregion

        /// <summary>
        /// UNSAFE. Use QueryLock_1X000 outside
        /// </summary>
        /// <returns></returns>
        public void DetachAllEntitiesAndDispose(bool detach = false, bool dispose = true)
        {
            if (_ObjectContextHelper != null && detach)
                _ObjectContextHelper.DetachAllEntities();
            if (dispose)
                Dispose();
        }

        public void Detach(object entity)
        {
            _ObjectContextHelper.Detach(entity);
        }

        public void AcceptAllChanges()
        {
            ((IACEntityObjectContext)ContextIPlus).ChangeTracker.AcceptAllChanges();
        }

        public DbSet<TEntity> CreateObjectSet<TEntity>() where TEntity : class
        {
            return ((IACEntityObjectContext)ContextIPlus).CreateObjectSet<TEntity>();
        }

        public DbSet<TEntity> CreateObjectSet<TEntity>(string entitySetName) where TEntity : class
        {
            return ((IACEntityObjectContext)ContextIPlus).CreateObjectSet<TEntity>(entitySetName);
        }

        public object GetObjectByKey(EntityKey key)
        {
            return _ObjectContextHelper.GetObjectByKey(key);
        }

        public bool TryGetObjectByKey(EntityKey key, out object entity)
        {
            return _ObjectContextHelper.TryGetObjectByKey(key, out entity);
        }
    }
}
