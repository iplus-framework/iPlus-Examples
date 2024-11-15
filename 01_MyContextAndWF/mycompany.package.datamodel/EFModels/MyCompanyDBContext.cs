using System;
using System.Collections.Generic;
using System.Configuration;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using gip.core.datamodel;
using mycompany.package.datamodel;

namespace mycompany.package.datamodel
{
    public partial class MyCompanyDBContext : DbContext
    {
        public MyCompanyDBContext()
        {
        }

        public MyCompanyDBContext(DbContextOptions<MyCompanyDBContext> options)
            : base(options)
        {
        }

        public virtual DbSet<InOrder> InOrder { get; set; }

        public virtual DbSet<InOrderPos> InOrderPos { get; set; }

        public virtual DbSet<Material> Material { get; set; }

        protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
        {
            optionsBuilder.AddInterceptors(new ACMaterializationInterceptor())
                .UseModel(MyCompanyDBContextModel.Instance)
                .ConfigureWarnings(warnings => warnings.Ignore(CoreEventId.ManyServiceProvidersCreatedWarning));
            //Uncomment connection string when generating new CompiledModels
//.UseSqlServer(ConfigurationManager.ConnectionStrings["MyCompanyDB_Entities"].ConnectionString);
        }

        protected override void OnModelCreating(ModelBuilder modelBuilder)
        {
            modelBuilder.Entity<InOrder>(entity =>
            {
                entity.ToTable("InOrder");

                entity.Property(e => e.InOrderID).ValueGeneratedNever();
                entity.Property(e => e.Comment).IsUnicode(false);
                entity.Property(e => e.InOrderDate).HasColumnType("datetime");
                entity.Property(e => e.InOrderNo)
                    .IsRequired()
                    .HasMaxLength(20)
                    .IsUnicode(false);
                entity.Property(e => e.InsertDate).HasColumnType("datetime");
                entity.Property(e => e.InsertName)
                    .IsRequired()
                    .HasMaxLength(5)
                    .IsUnicode(false);
                entity.Property(e => e.UpdateDate).HasColumnType("datetime");
                entity.Property(e => e.UpdateName)
                    .IsRequired()
                    .HasMaxLength(5)
                    .IsUnicode(false);
                entity.Property(e => e.XMLConfig).HasColumnType("text");
            });

            modelBuilder.Entity<InOrderPos>(entity =>
            {
                entity.Property(e => e.InOrderPosID).ValueGeneratedNever();
                entity.Property(e => e.InsertDate).HasColumnType("datetime");
                entity.Property(e => e.InsertName)
                    .IsRequired()
                    .HasMaxLength(5)
                    .IsUnicode(false);
                entity.Property(e => e.UpdateDate).HasColumnType("datetime");
                entity.Property(e => e.UpdateName)
                    .IsRequired()
                    .HasMaxLength(5)
                    .IsUnicode(false);
                entity.Property(e => e.XMLConfig).HasColumnType("text");

                entity.HasOne(d => d.InOrder).WithMany(p => p.InOrderPos_InOrder)
                     .HasForeignKey(d => d.InOrderID)
                     .HasConstraintName("FK_InOrderPos_InOrderID");

                entity.HasOne(d => d.Material).WithMany(p => p.InOrderPos_Material)
                     .HasForeignKey(d => d.MaterialID)
                     .OnDelete(DeleteBehavior.ClientSetNull)
                     .HasConstraintName("FK_InOrderPos_MaterialID");
            });

            modelBuilder.Entity<Material>(entity =>
            {
                entity.ToTable("Material");

                entity.Property(e => e.MaterialID).ValueGeneratedNever();
                entity.Property(e => e.DeleteDate).HasColumnType("datetime");
                entity.Property(e => e.DeleteName)
                    .HasMaxLength(5)
                    .IsUnicode(false);
                entity.Property(e => e.InsertDate).HasColumnType("datetime");
                entity.Property(e => e.InsertName)
                    .IsRequired()
                    .HasMaxLength(5)
                    .IsUnicode(false);
                entity.Property(e => e.MaterialName1)
                    .IsRequired()
                    .HasMaxLength(40)
                    .IsUnicode(false);
                entity.Property(e => e.MaterialNo)
                    .IsRequired()
                    .HasMaxLength(30)
                    .IsUnicode(false);
                entity.Property(e => e.UpdateDate).HasColumnType("datetime");
                entity.Property(e => e.UpdateName)
                    .IsRequired()
                    .HasMaxLength(5)
                    .IsUnicode(false);
                entity.Property(e => e.XMLConfig).HasColumnType("text");
            });

            OnModelCreatingPartial(modelBuilder);
        }

        partial void OnModelCreatingPartial(ModelBuilder modelBuilder);
    }
}
